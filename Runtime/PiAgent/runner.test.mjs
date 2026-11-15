import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
const runner = process.env.AGENTX_PI_RUNNER ?? new URL('./runner.mjs', import.meta.url).pathname;
const secret = 'private-test-key-never-log';
function run(payload, { timeout = 2000, signal } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [runner], { env: { PATH: '/usr/bin:/bin', AGENTX_PI_TIMEOUT_MS: String(timeout) }, signal });
    let out = '', err = '';
    child.stdout.on('data', x => { out += x; }); child.stderr.on('data', x => { err += x; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, out, err, value: (() => { try { return JSON.parse(out); } catch { return null; } })() }));
    child.stdin.on('error', () => {});
    child.stdin.end(typeof payload === 'string' ? payload : JSON.stringify(payload));
  });
}
async function fixture(handler, body) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try { return await body(`http://127.0.0.1:${server.address().port}/v1`); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}
function request(baseURL, model = 'new/model-a') {
  return { version: 1, baseURL, model, secret, metadata: { contextLength: 131072 }, messages: [
    { role: 'system', content: 'You are helpful.' }, { role: 'user', content: 'old question' },
    { role: 'assistant', content: 'old answer' }, { role: 'user', content: 'next question' }
  ] };
}
function sse(res, delta = { content: 'hello world' }, finish = 'stop') {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  res.end(`data: ${JSON.stringify({ id: 'local', object: 'chat.completion.chunk', choices: [{ index: 0, delta, finish_reason: null }] })}\n\ndata: ${JSON.stringify({ id: 'local', choices: [{ index: 0, delta: {}, finish_reason: finish }] })}\n\ndata: [DONE]\n\n`);
}
test('official Pi agent sends preserved history and newly selected dynamic models', async () => {
  const seen = [];
  await fixture(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    seen.push({ path: req.url, auth: req.headers.authorization, body: JSON.parse(raw) }); sse(res);
  }, async base => {
    for (const model of ['new/model-a', 'brand-new/model-b']) {
      const result = await run(request(base, model));
      assert.deepEqual(result.value, { version: 1, ok: true, text: 'hello world' }); assert.equal(result.err, '');
    }
  });
  assert.equal(seen.length, 2);
  for (let i = 0; i < 2; i++) {
    assert.equal(seen[i].body.model, ['new/model-a', 'brand-new/model-b'][i]);
    assert.equal(seen[i].path, '/v1/chat/completions'); assert.equal(seen[i].auth, `Bearer ${secret}`);
    assert.deepEqual(seen[i].body.messages.map(x => typeof x.content === 'string' ? x.content : x.content.map(c => c.text).join('')), ['You are helpful.', 'old question', 'old answer', 'next question']);
    assert.equal(seen[i].body.tools, undefined); assert.ok((seen[i].body.max_tokens ?? seen[i].body.max_completion_tokens) <= 1024);
  }
});
test('invalid input and unsafe endpoints are bounded and redacted', async () => {
  for (const data of ['{broken', 'x'.repeat(1_048_577), { ...request('https://openrouter.ai/api/v1'), secret: '' },
    ...['http://remote.test/v1', 'https://u:p@openrouter.ai/api/v1', 'https://openrouter.ai/api/v1?q=1', 'https://openrouter.ai/api/v1#', 'https://evil.test/v1'].map(base => request(base)),
    { ...request('http://127.0.0.1:1/v1'), messages: [{ role: 'tool', content: secret }] }]) {
    const result = await run(data);
    assert.equal(result.value?.ok, false); assert.equal(result.err, ''); assert.ok(!result.out.includes(secret));
    assert.ok(['invalid_request', 'missing_credential'].includes(result.value.code)); assert.ok(result.out.length < 200);
  }
});
test('provider errors, malformed streams, redirects, and tools never become successful replies', async () => {
  for (const mode of ['error', 'malformed', 'redirect', 'tool', 'length']) {
    let count = 0;
    await fixture((req, res) => {
      count++;
      if (mode === 'error') { res.writeHead(401); res.end(secret); }
      if (mode === 'malformed') { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end('data: not-json\n\n'); }
      if (mode === 'redirect') { res.writeHead(302, { location: '/leak' }); res.end(); }
      if (mode === 'tool') sse(res, { tool_calls: [{ index: 0, id: 'x', type: 'function', function: { name: 'dangerous', arguments: '{}' } }] }, 'tool_calls');
      if (mode === 'length') sse(res, { content: 'partial' }, 'length');
    }, async base => {
      const result = await run(request(base)); assert.equal(result.value?.ok, false, mode);
      assert.equal(result.err, ''); assert.ok(!result.out.includes(secret));
    });
    assert.equal(count, 1, mode);
  }
});
test('timeout aborts outstanding network request and exits', async () => {
  await fixture(() => {}, async base => {
    const start = Date.now(); const result = await run(request(base), { timeout: 80 });
    assert.equal(result.value?.code, 'timeout'); assert.ok(Date.now() - start < 2000);
  });
});
test('termination aborts pending request without outputting credential', async () => {
  await fixture(() => {}, async base => {
    const child = spawn(process.execPath, [runner], { env: {} }); let out = '', err = '';
    child.stdout.on('data', x => { out += x; }); child.stderr.on('data', x => { err += x; });
    const closed = once(child, 'close'); child.stdin.end(JSON.stringify(request(base)));
    await new Promise(resolve => setTimeout(resolve, 200)); child.kill('SIGTERM'); await closed;
    assert.ok(!out.includes(secret)); assert.equal(err, '');
  });
});

test('escaped text cannot exceed the stdout envelope bound or reflect a credential', async () => {
  for (const text of ['\x01'.repeat(24000), secret, 'x'.repeat(70000)]) {
    await fixture((req, res) => sse(res, { content: text }), async base => {
      const result = await run(request(base));
      assert.equal(result.value?.ok, false);
      assert.ok(Buffer.byteLength(result.out) <= 131072);
      assert.ok(!result.out.includes(secret));
    });
  }
});
