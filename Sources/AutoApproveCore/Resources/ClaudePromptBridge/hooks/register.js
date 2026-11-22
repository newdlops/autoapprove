let generation = 0
let suggestion = false
let timer

const invalidate = async ($, event, next) => {
  generation++
  suggestion = false
  return next(event)
}

export function register(on) {
  on('prompt.edit', invalidate)
  on('prompt.fill', invalidate)
  on('prompt.change', invalidate)
  on('prompt.submit', invalidate)
  on('prompt.suggest', async ($, event, next) => {
    const revision = ++generation
    suggestion = false
    const directory = await $.env.get('AUTOAPPROVE_CLAUDE_PROMPT_BRIDGE')
    if (directory && await $.fs.exists(directory + '/automatic')) return { isShown: false }
    const result = await next(event)
    if (revision === generation) suggestion = result?.isShown === true
    return result
  })
  on('session.start', async ($, event, next) => {
    timer?.cancel()
    suggestion = false
    generation++
    const directory = await $.env.get('AUTOAPPROVE_CLAUDE_PROMPT_BRIDGE')
    if (directory) {
      let handled
      timer = $.clock.every(750, async () => {
        const request = directory + '/request'
        if (!await $.fs.exists(request)) return
        const nonce = await $.fs.read(request)
        if (nonce === handled || !/^[0-9a-f-]{36}$/i.test(nonce)) return
        const revision = generation
        const session = await $.session.id()
        const buffer = await $.prompt.read()
        let state = revision !== generation || typeof buffer?.text !== 'string' ? 'unknown'
          : buffer.text.length ? 'draft' : suggestion ? 'suggestion' : 'empty'
        if (state === 'draft') {
          const challenge = directory + '/match-' + nonce
          if (await $.fs.exists(challenge)) {
            const expected = await $.fs.read(challenge)
            const bytes = new TextEncoder().encode(buffer.text.normalize('NFC'))
            const digest = await crypto.subtle.digest('SHA-256', bytes)
            const hex = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
            state = revision !== generation ? 'unknown' : hex === expected ? 'matchingDraft' : 'differentDraft'
          }
        }
        await $.fs.write(directory + '/' + nonce, JSON.stringify({nonce, session, state}))
        handled = nonce
      })
    }
    return next(event)
  })
}
