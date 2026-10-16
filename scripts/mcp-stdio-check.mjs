import {spawn} from 'node:child_process';
import {mkdtemp, rm} from 'node:fs/promises';
import {once} from 'node:events';
import path from 'node:path';
import assert from 'node:assert/strict';

// Exercise the actual CLI's byte-stream framing in an isolated profile. These
// requests never call a bridge tool, capture a screen or send terminal input.
const binary = path.resolve(process.argv[2] || '.build/release/autoapprove');
const home = await mkdtemp('/private/tmp/aa-mcp-stdio-');
const message = (id, method = 'ping', params) => ({jsonrpc:'2.0', id, method, ...(params ? {params} : {})});
const wire = value => Buffer.from(JSON.stringify(value));
const line = value => Buffer.concat([wire(value), Buffer.from('\n')]);
const maximum = 256_000;
function padded(size, ending = '\n') {
  const value = wire(message('boundary'));
  return Buffer.concat([value, Buffer.alloc(size - value.length, 32), Buffer.from(ending)]);
}
const result = id => ({jsonrpc:'2.0', id, result:{}});
const parseError = {jsonrpc:'2.0', id:null, error:{code:-32700, message:'Parse error'}};
const checked = [];
async function check(name, chunks, verify) {
  const child = spawn(binary, ['mcp', '--home', home], {env:{...process.env, HOME:home, ZDOTDIR:home}, stdio:['pipe','pipe','pipe']});
  const closed = once(child, 'close');
  const replies = []; let output = '', error = '', timer;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', part => { output += part; assert.ok(output.length < 1_000_000); });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', part => { error = (error + part).slice(-16_384); });
  try {
    const work = async () => {
      for (const chunk of chunks) {
        await new Promise((resolve, reject) => child.stdin.write(chunk, e => e ? reject(e) : resolve()));
        if (chunks.length > 1) await new Promise(resolve => setTimeout(resolve, 5));
      }
      child.stdin.end();
      const [code, signal] = await closed;
      assert.equal(code, 0, `${name}: ${signal || error}`);
      assert.ok(output === '' || output.endsWith('\n'), 'Every response must have a delimiter');
      for (const value of output.trimEnd().split('\n').filter(Boolean)) replies.push(JSON.parse(value));
      verify(replies); checked.push(name);
    };
    await Promise.race([work(), new Promise((_, reject) => { timer = setTimeout(() => reject(Error(`${name}: deadline`)), 10_000); })]);
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await closed;
  }
}
try {
  await check('clean EOF', [], values => assert.deepEqual(values, []));
  await check('coalesced requests, notification and IDs', [Buffer.concat([
    line(message(1, 'initialize', {protocolVersion:'2025-11-25'})),
    line({jsonrpc:'2.0', method:'notifications/initialized'}),
    line(message('문자🧪\u0000\u0004')), line(message(3, 'tools/list')), line(message(4, 'missing'))
  ])], values => {
    assert.equal(values.length, 4);
    assert.equal(values[0].id, 1); assert.equal(values[0].result.protocolVersion, '2025-11-25');
    assert.deepEqual(values[1], result('문자🧪\u0000\u0004'));
    assert.deepEqual(values[2].result.tools.map(tool => tool.name), ['ask_user','get_user_answers','list_screens','start_screen_share','stop_screen_share']);
    assert.equal(values[3].error.code, -32601);
  });
  const unicode = line(message('한글🧪'));
  const split = unicode.indexOf(Buffer.from('한')) + 1;
  await check('UTF-8 split inside a scalar', [unicode.subarray(0, split), unicode.subarray(split, split+2), unicode.subarray(split+2)], values => assert.deepEqual(values, [result('한글🧪')]));
  await check('CRLF', [Buffer.concat([wire(message(2)), Buffer.from('\r\n')])], values => assert.deepEqual(values, [result(2)]));
  await check('exact limit with LF', [padded(maximum)], values => assert.deepEqual(values, [result('boundary')]));
  await check('exact limit with CRLF', [padded(maximum, '\r\n')], values => assert.deepEqual(values, [result('boundary')]));
  await check('one byte over limit and next frame', [Buffer.concat([padded(maximum+1), line(message(5))])], values => assert.deepEqual(values, [parseError, result(5)]));
  await check('oversized fragmented line, one error, next frame', [Buffer.alloc(140_000,32), Buffer.alloc(140_000,32), Buffer.concat([Buffer.alloc(140_000,32), Buffer.from('\n'), line(message(6))])], values => assert.deepEqual(values, [parseError, result(6)]));
  await check('empty and malformed JSON then recovery', [Buffer.concat([Buffer.from('\n{broken}\n'), line(message(7))])], values => assert.deepEqual(values, [parseError, parseError, result(7)]));
  await check('malformed UTF-8 then recovery', [Buffer.concat([Buffer.from([0xff,10]), line(message(8))])], values => assert.deepEqual(values, [parseError, result(8)]));
  await check('UTF-16 is not a UTF-8 MCP frame', [Buffer.concat([Buffer.from(JSON.stringify(message(9)), 'utf16le'), Buffer.from('\n'), line(message(10))])], values => assert.deepEqual(values, [parseError, result(10)]));
  await check('unterminated valid final frame', [wire(message(11))], values => assert.deepEqual(values, [result(11)]));
  await check('unterminated oversized final frame', [padded(maximum+2, '')], values => assert.deepEqual(values, [parseError]));
  await check('notifications have no response', [line({jsonrpc:'2.0', method:'notifications/initialized'})], values => assert.deepEqual(values, []));
  console.log(JSON.stringify({passed:checked.length, checked, scope:'Actual isolated stdio CLI; no bridge tool calls, screen capture or original terminal input.'}));
} finally { await rm(home, {recursive:true, force:true}); }
