// Runs WebAuthn ceremonies for passkeys (RFD 19). The server builds the
// options and verifies the result; this hook only converts between the
// browser's ArrayBuffers and the base64url strings Renga sends and expects.
//
// The element says what to run with data attributes:
//
// * data-mode: "create" (register a passkey) or "get" (sign in or confirm).
// * data-options: the ceremony options as JSON. A LiveView can instead push
//   "passkey:start" with {target: <element id>, options}.
// * data-reply: a LiveView event that receives {response} or {error}. Without
//   it the element is a form: the response fills its hidden input marked
//   data-passkey-response and the form submits.
// * data-conditional: start a "get" right away with browser autofill, so a
//   saved passkey appears in the email field's suggestions.
//
// Clicking an element with data-passkey-start inside the hook starts the
// ceremony with the browser's own prompt.

const toBytes = value => {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0))
}

const toBase64url = buffer => {
  let binary = ""
  for (const byte of new Uint8Array(buffer)) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const descriptors = list => (list || []).map(credential => ({...credential, id: toBytes(credential.id)}))

const creationOptions = options => ({
  ...options,
  challenge: toBytes(options.challenge),
  user: {...options.user, id: toBytes(options.user.id)},
  excludeCredentials: descriptors(options.excludeCredentials),
})

const requestOptions = options => ({
  ...options,
  challenge: toBytes(options.challenge),
  allowCredentials: descriptors(options.allowCredentials),
})

const registrationJSON = credential => ({
  rawId: toBase64url(credential.rawId),
  clientDataJSON: toBase64url(credential.response.clientDataJSON),
  attestationObject: toBase64url(credential.response.attestationObject),
  transports: credential.response.getTransports ? credential.response.getTransports() : [],
})

const assertionJSON = credential => ({
  rawId: toBase64url(credential.rawId),
  clientDataJSON: toBase64url(credential.response.clientDataJSON),
  authenticatorData: toBase64url(credential.response.authenticatorData),
  signature: toBase64url(credential.response.signature),
  userHandle: credential.response.userHandle ? toBase64url(credential.response.userHandle) : null,
})

export const Passkey = {
  mounted() {
    this.onClick = event => {
      if (!event.target.closest("[data-passkey-start]")) return
      event.preventDefault()
      this.run(JSON.parse(this.el.dataset.options), "required")
    }
    this.el.addEventListener("click", this.onClick)

    this.handleEvent("passkey:start", ({target, options}) => {
      if (target === this.el.id) this.run(options, "required")
    })

    if (this.el.dataset.conditional !== undefined) this.startConditional()
  },

  destroyed() {
    this.abort?.abort()
    this.el.removeEventListener("click", this.onClick)
  },

  async startConditional() {
    const available =
      window.PublicKeyCredential?.isConditionalMediationAvailable &&
      (await PublicKeyCredential.isConditionalMediationAvailable())

    if (available) this.run(JSON.parse(this.el.dataset.options), "conditional")
  },

  async run(options, mediation) {
    // A modal prompt replaces a pending autofill request.
    this.abort?.abort()
    this.abort = new AbortController()

    if (!window.PublicKeyCredential) return this.fail("NotSupportedError")

    try {
      const credential =
        this.el.dataset.mode === "create"
          ? await navigator.credentials.create({publicKey: creationOptions(options), signal: this.abort.signal})
          : await navigator.credentials.get({
              publicKey: requestOptions(options),
              mediation,
              signal: this.abort.signal,
            })

      const response = this.el.dataset.mode === "create" ? registrationJSON(credential) : assertionJSON(credential)
      this.succeed(response)
    } catch (error) {
      // Autofill fails quietly: the person simply didn't pick a passkey.
      if (error.name !== "AbortError" && mediation !== "conditional") this.fail(error.name)
    }
  },

  succeed(response) {
    if (this.el.dataset.reply) {
      this.pushEvent(this.el.dataset.reply, {response})
    } else {
      this.el.querySelector("[data-passkey-response]").value = JSON.stringify(response)
      this.el.submit()
    }
  },

  fail(name) {
    if (this.el.dataset.reply) {
      this.pushEvent(this.el.dataset.reply, {error: name})
    } else {
      const status = this.el.querySelector("[data-passkey-status]")
      if (status) status.textContent = "The passkey didn't work. Try again, or use your email."
    }
  },
}
