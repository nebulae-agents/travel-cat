// One request per process. Credentials are read exclusively from stdin.
const MAX_REQUEST = 1_048_576;
const MAX_TEXT = 65_536;
const MAX_RESPONSE = 2_097_152;
const streamLoopback = process.argv[2] === '--stream-loopback';
const safeError = code => Object.assign(new Error(code), { safeCode: code });
// Dependency diagnostics must never expose provider responses or credentials.
for (const name of ['log', 'error', 'warn', 'info', 'debug', 'trace']) console[name] = () => {};
// The desktop can die without sending SIGTERM. Check the expected parent before
// reading a request and during streaming; an orphan must close its upstream socket.
if (process.env.AGENTX_PI_OWNER_PID !== undefined) {
  const owner = Number(process.env.AGENTX_PI_OWNER_PID);
  const checkOwner = () => {
    if (!Number.isSafeInteger(owner) || owner <= 1 || process.ppid !== owner) process.exit(1);
  };
  checkOwner();
  setInterval(checkOwner, 200).unref();
}
let agent;
let interrupted = false;
process.on('SIGTERM', () => { interrupted = true; if (agent) agent.abort(); else process.exit(0); });
process.on('SIGINT', () => { interrupted = true; if (agent) agent.abort(); else process.exit(0); });
process.on('uncaughtException', () => process.exit(1));
process.on('unhandledRejection', () => process.exit(1));

function validate(value) {
  if (!value || value.version !== 1 || typeof value.baseURL !== 'string' || typeof value.model !== 'string' ||
      !value.model.trim() || value.model.length > 512 || /[\x00-\x1f\x7f]/.test(value.model)) throw safeError('invalid_request');
  let url; try { url = new URL(value.baseURL); } catch { throw safeError('invalid_request'); }
  const official = url.protocol === 'https:' && url.hostname === 'openrouter.ai' && (!url.port || url.port === '443') && /^\/api\/v1\/?$/.test(url.pathname);
  const local = url.protocol === 'http:' && ['127.0.0.1', '[::1]'].includes(url.hostname);
  if ((!official && !local) || url.username || url.password || value.baseURL.includes('?') || value.baseURL.includes('#')) throw safeError('invalid_request');
  if (typeof value.secret !== 'string' || value.secret.length > 8192 || /[\r\n\x00]/.test(value.secret)) throw safeError('invalid_request');
  if (streamLoopback && (!local || value.secret !== '')) throw safeError('invalid_request');
  if (value.gatewayToken !== undefined && (!streamLoopback || !local || value.secret !== '' ||
      typeof value.gatewayToken !== 'string' || !/^[a-f0-9-]{72}$/.test(value.gatewayToken) ||
      !Number.isSafeInteger(value.maxOutputTokens) || value.maxOutputTokens < 1 || value.maxOutputTokens > 65536 ||
      !Number.isSafeInteger(value.timeoutSeconds) || value.timeoutSeconds < 1 || value.timeoutSeconds > 300)) throw safeError('invalid_request');
  if (official && !value.secret.trim()) throw safeError('missing_credential');
  if (!Array.isArray(value.messages) || !value.messages.length || value.messages.length > 512 || value.messages.at(-1)?.role !== 'user') throw safeError('invalid_request');
  for (let index = 0; index < value.messages.length; index++) {
    const message = value.messages[index];
    if (!message || !['system', 'user', 'assistant'].includes(message.role) || typeof message.content !== 'string' ||
        (message.role === 'system' && index !== 0)) throw safeError('invalid_request');
  }
  return value;
}
async function readRequest() {
  const chunks = []; let length = 0;
  for await (const chunk of process.stdin) {
    length += chunk.length;
    if (length > MAX_REQUEST) throw safeError('invalid_request');
    chunks.push(chunk);
  }
  try { return validate(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
  catch (error) { throw safeError(error.safeCode ?? 'invalid_request'); }
}
// The SDK also initializes a zero usage object for providers which omit usage.
// Observe raw completion chunks before normalization and publish only the two reported counts.
function writeProgress(frame) {
  return new Promise((resolve, reject) => process.stdout.write(JSON.stringify(frame) + '\n', error => error ? reject(error) : resolve()));
}
async function respond(request) {
  let measuredUsage;
  let visibleBytes = 0;
  const onProviderStreamEvent = async chunk => {
    const choice = chunk?.choices?.[0];
    const usage = chunk?.usage ?? choice?.usage;
    if (Number.isSafeInteger(usage?.prompt_tokens) && usage.prompt_tokens >= 0 &&
        Number.isSafeInteger(usage?.completion_tokens) && usage.completion_tokens >= 0) {
      if (request.gatewayToken && measuredUsage) throw safeError('provider_error');
      measuredUsage = { event: 'usage', input: usage.prompt_tokens, output: usage.completion_tokens };
      if (request.gatewayToken) await writeProgress(measuredUsage);
    }
    const text = choice?.delta?.content;
    if (text == null || text === '') return;
    if (typeof text !== 'string' || !text.isWellFormed()) throw safeError('provider_error');
    visibleBytes += Buffer.byteLength(text);
    if (visibleBytes > MAX_TEXT) throw safeError('provider_error');
    // Keep each record small without splitting a Unicode scalar. Await each write so
    // a slow host applies backpressure to the SDK's upstream iteration.
    for (let start = 0; start < text.length;) {
      let end = Math.min(start + 1024, text.length);
      if (end < text.length && text.charCodeAt(end) >= 0xdc00 && text.charCodeAt(end) <= 0xdfff) end--;
      await writeProgress({ event: 'text', text: text.slice(start, end) });
      start = end;
    }
  };
  const [{ Agent }, { streamSimple }] = await Promise.all([
    import('@earendil-works/pi-agent-core'), import('@earendil-works/pi-ai/api/openai-completions')
  ]);
  const model = {
    id: request.model, name: request.model, api: 'openai-completions', provider: 'openrouter', baseUrl: request.baseURL.replace(/\/$/, ''),
    reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: Number.isSafeInteger(request.metadata?.contextLength) && request.metadata.contextLength > 0 ? request.metadata.contextLength : 32768,
    maxTokens: request.gatewayToken ? request.maxOutputTokens : 1024
  };
  const messages = request.messages.filter(x => x.role !== 'system');
  const history = messages.slice(0, -1).map(message => message.role === 'user' ? { ...message, timestamp: Date.now() } : {
    role: 'assistant', content: [{ type: 'text', text: message.content }], api: model.api, provider: model.provider, model: model.id,
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: 'stop', timestamp: Date.now()
  });
  let timedOut = false; let toolRequested = false;
  const timeout = request.gatewayToken ? request.timeoutSeconds * 1000 : Math.min(60000, Math.max(1, Number(process.env.AGENTX_PI_TIMEOUT_MS) || 60000));
  const fetchBounded = async (input, init) => {
    const options = { ...init, redirect: 'error' };
    if (streamLoopback) {
      options.headers = new Headers(init?.headers ?? input.headers);
      options.headers.delete('authorization');
      if (request.gatewayToken) options.headers.set('authorization', `Bearer ${request.gatewayToken}`);
    }
    const response = await fetch(input, options);
    if (!response.ok || !response.body) throw safeError('provider_error');
    const reader = response.body.getReader(); let received = 0;
    return new Response(new ReadableStream({
      async pull(controller) {
        try {
          const { done, value } = await reader.read();
          if (done) { controller.close(); return; }
          received += value.byteLength;
          if (received > MAX_RESPONSE) { await reader.cancel(); controller.error(safeError('provider_error')); return; }
          controller.enqueue(value);
        } catch { controller.error(safeError('provider_error')); }
      }, cancel() { return reader.cancel(); }
    }), { status: response.status, headers: response.headers });
  };
  agent = new Agent({
    initialState: { systemPrompt: request.messages[0]?.role === 'system' ? request.messages[0].content : '', model, messages: history, tools: [] },
    getApiKey: () => request.secret || 'loopback-no-auth',
    streamFn: (selectedModel, context, options) => streamSimple(selectedModel, context, {
      ...options, apiKey: request.secret || 'loopback-no-auth', env: {}, fetch: fetchBounded,
      ...(streamLoopback ? { onProviderStreamEvent } : {}),
      maxTokens: request.gatewayToken ? request.maxOutputTokens : 1024, maxRetries: 0, timeoutMs: timeout, cacheRetention: 'none'
    }),
    beforeToolCall: () => { toolRequested = true; agent.abort(); return { block: true, reason: 'Tools are disabled' }; },
    identity: { attribution: null }
  });
  agent.subscribe(event => {
    if ((event.type === 'message_update' || event.type === 'message_end') && event.message?.role === 'assistant') {
      if (event.message.content.some(x => x.type === 'toolCall')) { toolRequested = true; agent.abort(); }
      const length = event.message.content.reduce((n, x) => n + Buffer.byteLength(x.text ?? x.thinking ?? ''), 0);
      if (length > MAX_TEXT) agent.abort();
    }
  });
  const timer = setTimeout(() => { timedOut = true; agent.abort(); }, timeout);
  try {
    await agent.prompt(messages.at(-1).content); await agent.waitForIdle();
    if (timedOut) throw safeError('timeout');
    if (interrupted) throw safeError('cancelled');
    if (toolRequested) throw safeError('tools_disabled');
    const result = agent.state.messages.at(-1);
    if (result?.role !== 'assistant' || result.stopReason !== 'stop') throw safeError('provider_error');
    const text = result.content.filter(x => x.type === 'text').map(x => x.text).join('');
    if (!text.trim() || Buffer.byteLength(text) > MAX_TEXT || (request.secret && text.includes(request.secret))) throw safeError('provider_error');
    const resultFrame = { version: 1, ok: true, text };
    if (streamLoopback && !request.gatewayToken && measuredUsage && Buffer.byteLength(JSON.stringify(resultFrame) + '\n') <= 131072) {
      await writeProgress(measuredUsage);
    }
    return resultFrame;
  } catch (error) { throw safeError(timedOut ? 'timeout' : interrupted ? 'cancelled' : toolRequested ? 'tools_disabled' : error.safeCode ?? 'provider_error'); }
  finally { clearTimeout(timer); agent.abort(); await agent.waitForIdle(); }
}
let result;
const inputTimer = setTimeout(() => { process.stdout.write('{"version":1,"ok":false,"code":"invalid_request"}\n'); process.exit(0); }, 5000);
try { const request = await readRequest(); clearTimeout(inputTimer); result = await respond(request); }
catch (error) { result = { version: 1, ok: false, code: error.safeCode ?? 'runtime_error' }; }
finally { clearTimeout(inputTimer); }
let encoded = JSON.stringify(result) + '\n';
if (Buffer.byteLength(encoded) > 131072) encoded = '{"version":1,"ok":false,"code":"provider_error"}\n';
process.stdout.write(encoded, () => process.exit(0));
