//! Small monotonic scheduler, kept independent of sleeping for deterministic tests.

use crate::cancellation::Cancellation;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Job {
    CheckIn,
    Inventory,
    Reload,
}

pub struct Scheduler {
    checkin: Instant,
    inventory: Instant,
    reload: Instant,
}

impl Scheduler {
    pub fn new(now: Instant, checkin: Duration, inventory: Duration, reload: Duration) -> Self {
        Self {
            checkin: now + checkin,
            inventory: now + inventory,
            reload: now + reload,
        }
    }

    pub fn due(&self, now: Instant) -> Vec<Job> {
        [
            (Job::CheckIn, self.checkin),
            (Job::Inventory, self.inventory),
            (Job::Reload, self.reload),
        ]
        .into_iter()
        .filter_map(|(job, at)| (at <= now).then_some(job))
        .collect()
    }

    pub fn due_until_cancelled<'a>(
        &self,
        now: Instant,
        stopped: &'a Cancellation,
    ) -> impl Iterator<Item = Job> + 'a {
        self.due(now)
            .into_iter()
            .take_while(move |_| !stopped.cancelled())
    }

    pub fn reschedule(&mut self, job: Job, now: Instant, interval: Duration) {
        let next = now + interval;
        match job {
            Job::CheckIn => self.checkin = next,
            Job::Inventory => self.inventory = next,
            Job::Reload => self.reload = next,
        }
    }

    pub fn refresh_intervals(
        &mut self,
        now: Instant,
        old_checkin: Duration,
        new_checkin: Duration,
        old_inventory: Duration,
        new_inventory: Duration,
    ) {
        if old_checkin != new_checkin {
            // A reload may accelerate lease renewal, but it must never postpone a renewal that
            // was already promised under the previous configuration.
            self.checkin = self.checkin.min(now + new_checkin);
        }
        if old_inventory != new_inventory {
            self.reschedule(Job::Inventory, now, new_inventory);
        }
    }

    pub fn wait(&self, now: Instant) -> Duration {
        [self.checkin, self.inventory, self.reload]
            .into_iter()
            .min()
            .unwrap()
            .saturating_duration_since(now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unchanged_refreshes_preserve_the_original_inventory_deadline() {
        let started = Instant::now();
        let checkin = Duration::from_secs(30);
        let inventory = Duration::from_secs(60);
        let refresh = Duration::from_secs(10);
        let mut scheduler = Scheduler::new(started, checkin, inventory, refresh);

        for elapsed in [10, 20, 30, 40, 50] {
            let refreshed_at = started + Duration::from_secs(elapsed);
            scheduler.refresh_intervals(refreshed_at, checkin, checkin, inventory, inventory);
            scheduler.reschedule(Job::Reload, refreshed_at, refresh);
        }

        assert!(scheduler
            .due(started + Duration::from_secs(59))
            .iter()
            .all(|job| *job != Job::Inventory));
        assert!(scheduler.due(started + inventory).contains(&Job::Inventory));
    }

    #[test]
    fn credential_only_refresh_preserves_checkin_and_inventory_deadlines() {
        let started = Instant::now();
        let checkin = Duration::from_secs(20);
        let inventory = Duration::from_secs(60);
        let mut scheduler = Scheduler::new(started, checkin, inventory, Duration::from_secs(5));

        scheduler.refresh_intervals(
            started + Duration::from_secs(5),
            checkin,
            checkin,
            inventory,
            inventory,
        );

        let due = scheduler.due(started + checkin);
        assert!(due.contains(&Job::CheckIn));
        assert!(!due.contains(&Job::Inventory));
    }

    #[test]
    fn changed_intervals_are_measured_from_refresh_completion() {
        let started = Instant::now();
        let refreshed_at = started + Duration::from_secs(5);
        let mut scheduler = Scheduler::new(
            started,
            Duration::from_secs(20),
            Duration::from_secs(60),
            Duration::from_secs(5),
        );

        scheduler.refresh_intervals(
            refreshed_at,
            Duration::from_secs(20),
            Duration::from_secs(10),
            Duration::from_secs(60),
            Duration::from_secs(30),
        );

        let due = scheduler.due(refreshed_at + Duration::from_secs(10));
        assert!(due.contains(&Job::CheckIn));
        assert!(!due.contains(&Job::Inventory));
        assert!(scheduler
            .due(refreshed_at + Duration::from_secs(30))
            .contains(&Job::Inventory));
    }

    #[test]
    fn changed_checkin_interval_never_postpones_pending_lease_renewal() {
        let started = Instant::now();
        let mut scheduler = Scheduler::new(
            started,
            Duration::from_secs(60),
            Duration::from_secs(3600),
            Duration::from_secs(59),
        );

        scheduler.refresh_intervals(
            started + Duration::from_secs(59),
            Duration::from_secs(60),
            Duration::from_secs(59),
            Duration::from_secs(3600),
            Duration::from_secs(3600),
        );

        assert!(scheduler
            .due(started + Duration::from_secs(60))
            .contains(&Job::CheckIn));
    }

    #[test]
    fn jobs_become_due_and_accept_refreshed_intervals() {
        let now = Instant::now();
        let mut scheduler = Scheduler::new(
            now,
            Duration::from_secs(2),
            Duration::from_secs(3),
            Duration::from_secs(4),
        );
        assert!(scheduler.due(now).is_empty());
        assert_eq!(
            scheduler.due(now + Duration::from_secs(3)),
            vec![Job::CheckIn, Job::Inventory]
        );
        scheduler.reschedule(Job::CheckIn, now, Duration::from_secs(10));
        assert_eq!(
            scheduler.due(now + Duration::from_secs(4)),
            vec![Job::Inventory, Job::Reload]
        );
        assert_eq!(scheduler.wait(now), Duration::from_secs(3));
    }

    #[test]
    fn startup_work_does_not_shift_first_checkin_deadline() {
        let startup_began = Instant::now();
        let scheduler = Scheduler::new(
            startup_began,
            Duration::from_secs(60),
            Duration::from_secs(3600),
            Duration::from_secs(300),
        );

        assert!(scheduler
            .due(startup_began + Duration::from_secs(60))
            .contains(&Job::CheckIn));
    }

    #[test]
    fn cancellation_stops_remaining_due_jobs() {
        let stopped = Cancellation::default();
        let now = Instant::now();
        let scheduler = Scheduler::new(now, Duration::ZERO, Duration::ZERO, Duration::ZERO);
        let mut jobs = scheduler.due_until_cancelled(now, &stopped);
        assert_eq!(jobs.next(), Some(Job::CheckIn));
        stopped.cancel();
        assert_eq!(jobs.next(), None);
    }
}
