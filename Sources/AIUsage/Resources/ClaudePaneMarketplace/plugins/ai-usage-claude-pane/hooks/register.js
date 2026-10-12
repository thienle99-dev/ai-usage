const PANE = 'ai-usage-claude-pane'
const SNAPSHOT_PATH = 'Library/Application Support/AIUsage/snapshots.json'
const SESSION_REFRESH_MS = 15000
const QUOTA_REFRESH_MS = 60000
const DONE_RETENTION_MS = 300000
const RESPONSE_MODES_PATH = 'Library/Application Support/AIUsage/ClaudePane/response-modes.json'

let quotaRows = []
let quotaError = ''
let conversations = []
let conversationError = ''
let agents = []
let backgroundTasks = []
let shellRuns = []
let activeTab = 'overview'
let lastQuotaRefresh = 0
let sessionTimer
let quotaTimer
let activeResponseModes = []

const providerOrder = ['Claude', 'Codex', 'Copilot', 'Cursor', 'Gemini', 'Antigravity', 'Grok', 'OpenCode']
const providerNames = {
  Claude: 'Claude', Codex: 'Codex', Copilot: 'Copilot', Cursor: 'Cursor',
  Gemini: 'Gemini', Antigravity: 'Antigravity', Grok: 'Grok', OpenCode: 'OpenCode',
}

function redraw($) {
  $.ui.invalidate('ui.render')
}

function ageLabel(timestamp, now) {
  const elapsed = Math.max(0, Math.floor((now - timestamp) / 1000))
  if (elapsed < 60) return `${elapsed}s ago`
  if (elapsed < 3600) return `${Math.floor(elapsed / 60)}m ago`
  return `${Math.floor(elapsed / 3600)}h ago`
}

function resetLabel(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return ''
  // Swift JSONEncoder dates are seconds since 2001-01-01.
  const resetAt = value > 100000000000 ? value : (value + 978307200) * 1000
  const remaining = Math.floor((resetAt - Date.now()) / 1000)
  if (remaining <= 0) return 'resetting'
  if (remaining < 3600) return `${Math.floor(remaining / 60)}m`
  if (remaining < 86400) return `${Math.floor(remaining / 3600)}h ${Math.floor(remaining % 3600 / 60)}m`
  return `${Math.floor(remaining / 86400)}d ${Math.floor(remaining % 86400 / 3600)}h`
}

async function refreshQuota($) {
  const home = (await $.env.get('HOME')) || ''
  if (!home) {
    quotaRows = []
    quotaError = 'HOME is unavailable'
    return
  }
  try {
    const text = await $.fs.read(`${home}/${SNAPSHOT_PATH}`)
    const snapshots = JSON.parse(text)
    if (!Array.isArray(snapshots)) throw new Error('Invalid local usage snapshot')
    quotaRows = snapshots.flatMap(snapshot => {
      if (!snapshot || typeof snapshot.provider !== 'string' || !Array.isArray(snapshot.windows)) return []
      const provider = providerNames[snapshot.provider]
      if (!provider) return []
      const windows = snapshot.windows.filter(window =>
        window && typeof window.label === 'string' && typeof window.utilization === 'number'
          && Number.isFinite(window.utilization) && window.utilization >= 0 && window.utilization <= 100)
      if (!windows.length) return []
      const stale = !!snapshot.error || typeof snapshot.lastSuccess !== 'number'
        || Date.now() - (snapshot.lastSuccess + 978307200) * 1000 > 15 * 60 * 1000
      return [{ provider, account: typeof snapshot.account === 'string' ? snapshot.account : '', windows, stale }]
    }).sort((left, right) => providerOrder.indexOf(left.provider) - providerOrder.indexOf(right.provider))
    quotaError = quotaRows.length ? '' : 'No cached quota yet. Refresh AI Usage Monitor first.'
    lastQuotaRefresh = Date.now()
  } catch (_) {
    quotaRows = []
    quotaError = 'Local quota snapshot unavailable'
  }
  redraw($)
}

function parseSession(text) {
  try {
    const row = JSON.parse(text)
    if (!row || !Number.isSafeInteger(row.pid) || row.pid <= 0 || typeof row.sessionId !== 'string' || !row.sessionId) return null
    if (typeof (row.statusUpdatedAt ?? row.updatedAt) !== 'number') return null
    return {
      pid: row.pid,
      sessionId: row.sessionId,
      name: typeof row.name === 'string' ? row.name.trim() : '',
      cwd: typeof row.cwd === 'string' ? row.cwd : '',
      status: typeof row.status === 'string' ? row.status : 'idle',
      updatedAt: row.statusUpdatedAt ?? row.updatedAt,
      waitingFor: typeof row.waitingFor === 'string' ? row.waitingFor.trim() : '',
    }
  } catch (_) {
    return null
  }
}

async function refreshConversations($) {
  const home = (await $.env.get('HOME')) || ''
  if (!home) {
    conversations = []
    conversationError = 'HOME is unavailable'
    return
  }
  try {
    const entries = await $.fs.list(`${home}/.claude/sessions`)
    const candidates = []
    for (const file of entries) {
      if (file.kind !== 'file' || file.isLink || !file.name.endsWith('.json')) continue
      try {
        const row = parseSession(await $.fs.read(`${home}/.claude/sessions/${file.name}`))
        if (row) candidates.push(row)
      } catch (_) { /* Skip records removed while scanning. */ }
    }
    let livePIDs = new Set()
    if (candidates.length) {
      try {
        const result = await $.process.run(['ps', '-o', 'pid=', '-p', candidates.map(row => row.pid).join(',')], { timeoutMs: 3000 })
        if (result.exitCode === 0) livePIDs = new Set(result.stdout.trim().split(/\s+/).map(Number))
      } catch (_) { /* Process listing may be blocked by the environment. */ }
    }
    const current = await $.session.id()
    conversations = candidates.filter(row => livePIDs.has(row.pid)).map(row => ({
      ...row,
      title: row.name || row.cwd.replace(/[\\/]+$/, '').split(/[\\/]+/).pop() || row.sessionId.slice(0, 8),
      current: row.sessionId === current,
    })).sort((left, right) => Number(right.current) - Number(left.current)
      || Number(right.status === 'busy') - Number(left.status === 'busy')
      || right.updatedAt - left.updatedAt).slice(0, 12)
    conversationError = ''
  } catch (_) {
    conversations = []
    conversationError = 'Claude Code session list unavailable'
  }
  redraw($)
}

async function refreshAgents($) {
  try {
    const rows = await $.agent.list()
    agents = Array.isArray(rows) ? rows.filter(row => row && ['pending', 'running', 'waiting'].includes(row.status)) : []
  } catch (_) {
    agents = []
  }
  redraw($)
}

function activeJobs(now) {
  const runs = shellRuns.filter(run => run.end === null || now - run.end < DONE_RETENTION_MS)
  const tasks = backgroundTasks.filter(task => now - task.start < 60 * 60 * 1000)
  return { runs, tasks, agents }
}

async function refreshAll($) {
  if (Date.now() - lastQuotaRefresh >= QUOTA_REFRESH_MS) await refreshQuota($)
  await Promise.all([refreshConversations($), refreshAgents($)])
}

async function responseModeContext($) {
  activeResponseModes = []
  try {
    const home = (await $.env.get('HOME')) || ''
    if (!home) return ''
    const saved = JSON.parse(await $.fs.read(`${home}/${RESPONSE_MODES_PATH}`))
    const instructions = []
    if (saved?.tokenSaver === true) {
      activeResponseModes.push('Token Saver')
      instructions.push('Token Saver mode: Keep your answer concise and direct. Avoid repeating context, include only necessary examples, and preserve critical reasoning and caveats.')
    }
    if (saved?.beginner === true) {
      activeResponseModes.push('Beginner Mode')
      instructions.push('Beginner Mode: Explain unfamiliar technical terms in plain language the first time they appear. Add a brief example when it helps, without assuming prior expertise.')
    }
    return instructions.length ? `[AI Usage Monitor response preferences]\n${instructions.join('\n')}` : ''
  } catch (_) {
    activeResponseModes = []
    return ''
  }
}

function panelText(Text, value, options = {}) {
  return Text({ children: [value], ...options })
}

function quotaView(Box, Text) {
  const rows = []
  if (activeResponseModes.length) {
    rows.push(panelText(Text, `Response modes · ${activeResponseModes.join(' + ')}`, { dimColor: true }))
  }
  for (const item of quotaRows) {
    rows.push(panelText(Text, `${item.provider}${item.account ? ` · ${item.account}` : ''}${item.stale ? ' · stale' : ''}`, { bold: true }))
    for (const window of item.windows) {
      const used = Math.round(window.utilization)
      const barWidth = 12
      const filled = Math.round(used * barWidth / 100)
      const reset = resetLabel(window.resetsAt)
      rows.push(panelText(Text, `  ${window.label} ${'━'.repeat(filled)}${'─'.repeat(barWidth - filled)} ${used}%${reset ? ` · ↻ ${reset}` : ''}`, {
        color: used >= 90 ? 'red' : used >= 70 ? 'yellow' : undefined,
      }))
    }
  }
  if (quotaError) rows.push(panelText(Text, quotaError, { color: 'yellow' }))
  return Box({ flexDirection: 'column', rowGap: 1, children: rows })
}

function conversationsView(Box, Text, now) {
  const rows = conversations.map(row => {
    const marker = row.status === 'waiting' || row.waitingFor ? '?' : row.status === 'busy' ? '●' : '○'
    const state = row.waitingFor ? `waiting: ${row.waitingFor}` : row.status
    const path = row.cwd.replace(/[\\/]+$/, '').split(/[\\/]+/).pop() || ''
    return panelText(Text, `${marker} ${row.current ? 'HERE · ' : ''}${row.title}${path && path !== row.title ? ` · ${path}` : ''} · ${state} · ${ageLabel(row.updatedAt, now)}`, {
      color: row.status === 'busy' ? 'green' : row.status === 'waiting' || row.waitingFor ? 'yellow' : undefined,
      wrap: 'truncate-end',
    })
  })
  if (!rows.length) rows.push(panelText(Text, conversationError || 'No live Claude Code conversations found.', { dimColor: true }))
  if (conversationError) rows.push(panelText(Text, conversationError, { color: 'yellow' }))
  return Box({ flexDirection: 'column', rowGap: 1, children: rows })
}

function jobsView(Box, Text, now) {
  const { runs, tasks, agents: activeAgents } = activeJobs(now)
  const rows = []
  for (const agent of activeAgents) {
    rows.push(panelText(Text, `${agent.status === 'waiting' ? '?' : '●'} ${agent.type || 'Agent'} · ${agent.description || agent.id || 'Background agent'}`, {
      color: agent.status === 'waiting' ? 'yellow' : 'green', wrap: 'truncate-end',
    }))
  }
  for (const task of tasks) {
    rows.push(panelText(Text, `● ${task.type || 'Task'} · ${task.label || task.description || 'Background task'} · ${ageLabel(task.start, now)}`, {
      color: 'green', wrap: 'truncate-end',
    }))
  }
  for (const run of runs) {
    const elapsed = Math.max(0, Math.floor(((run.end ?? now) - run.start) / 1000))
    rows.push(panelText(Text, `${run.end === null ? '●' : run.status === 'completed' ? '✓' : '×'} ${run.label || 'Shell task'} · ${elapsed}s${run.end === null ? '' : ` · ${run.status}`}`, {
      color: run.end === null ? 'green' : undefined, dimColor: run.end !== null, wrap: 'truncate-end',
    }))
  }
  if (!rows.length) rows.push(panelText(Text, 'No background jobs.', { dimColor: true }))
  return Box({ flexDirection: 'column', rowGap: 1, children: rows })
}

export function register(on) {
  on('session.start', async ($, event, next) => {
    await $.command.register({ name: 'usage-pane', description: 'Open cached quotas, conversations, and background jobs' })
    await $.ui.open({ id: PANE, title: 'AI Usage', columns: 42, rows: 14, closeOnEscape: true })
    sessionTimer?.cancel()
    quotaTimer?.cancel()
    sessionTimer = $.clock.every(SESSION_REFRESH_MS, () => refreshAll($))
    quotaTimer = $.clock.every(QUOTA_REFRESH_MS, () => refreshQuota($))
    await responseModeContext($)
    await refreshAll($)
    return next(event)
  })

  on('prompt.submit', async ($, event, next) => {
    const extraContext = await responseModeContext($)
    if (!extraContext) return next(event)
    return next({ ...event, context: [...(event.context || []), extraContext] })
  }).catch(async ($, event, next) => next(event))

  on('command.run', { command: 'usage-pane' }, async $ => {
    await $.ui.open({ id: PANE, title: 'AI Usage', columns: 42, rows: 14, closeOnEscape: true })
    return {}
  })

  on('classic.Stop', async ($, event, next) => {
    const result = await next(event)
    const now = Date.now()
    if (Array.isArray(event.background_tasks)) {
      backgroundTasks = event.background_tasks.filter(task => task && typeof task === 'object')
        .map(task => ({ id: String(task.id || task.taskId || ''), type: String(task.type || 'Task'), label: String(task.description || task.command || ''), start: typeof task.start === 'number' ? task.start : now }))
    }
    shellRuns = shellRuns.filter(run => run.end === null || now - run.end < DONE_RETENTION_MS)
    redraw($)
    return result
  }).catch(async ($, event, next) => next(event))

  on('tool.call', { tool: 'Bash' }, async ($, event, next) => {
    const run = { id: event.tool_use_id || `shell-${Date.now()}`, label: String(event.description || event.command || 'Shell command').slice(0, 80), start: Date.now(), end: null, status: 'running' }
    shellRuns.push(run)
    redraw($)
    const result = await next(event)
    const at = shellRuns.findIndex(item => item.id === run.id)
    if (at >= 0) {
      const response = result?.result
      const taskId = response && typeof response.backgroundTaskId === 'string' ? response.backgroundTaskId : ''
      if (taskId) {
        backgroundTasks = [...backgroundTasks.filter(task => task.id !== taskId), { id: taskId, type: 'Shell', label: run.label, start: run.start }]
        shellRuns.splice(at, 1)
      } else {
        shellRuns[at] = { ...run, end: Date.now(), status: result?.isError ? 'failed' : 'completed' }
      }
    }
    redraw($)
    return result
  }).catch(async ($, event, next) => next(event))

  on('ui.render', { component: 'Pane' }, async ($, event, next) => {
    if (event.requestId !== PANE) return next(event)
    const { Box, Text, Button } = $.ui.resolve(event)
    const now = Date.now()
    const jobs = activeJobs(now)
    const jobCount = jobs.runs.filter(run => run.end === null).length + jobs.tasks.length + jobs.agents.length
    const tabs = [
      ['overview', 'Overview', '1'],
      ['conversations', `Sessions (${conversations.length})`, '2'],
      ['jobs', `Jobs (${jobCount})`, '3'],
    ].map(([id, label, hotkey]) => Button({
      key: `tab-${id}`, label, hotkey, plain: true, dimColor: activeTab !== id,
      onPress: () => { activeTab = id; redraw($) },
    }))
    const body = activeTab === 'overview'
      ? quotaView(Box, Text)
      : activeTab === 'conversations'
        ? conversationsView(Box, Text, now)
        : jobsView(Box, Text, now)
    return Box({ flexDirection: 'column', rowGap: 1, children: [
      Box({ flexDirection: 'row', columnGap: 2, children: tabs }),
      panelText(Text, activeTab === 'overview' ? 'Cached usage · local only' : activeTab === 'conversations' ? 'Live Claude Code sessions' : 'Agents and background work', { dimColor: true }),
      body,
    ] })
  })
}
