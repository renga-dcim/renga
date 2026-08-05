//! Small monotonic scheduler, kept independent of sleeping for deterministic tests.

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

    pub fn reschedule(&mut self, job: Job, now: Instant, interval: Duration) {
        let next = now + interval;
        match job {
            Job::CheckIn => self.checkin = next,
            Job::Inventory => self.inventory = next,
            Job::Reload => self.reload = next,
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
}
