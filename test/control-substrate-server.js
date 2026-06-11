// Trivial HTTP server. Listens on :9222 and answers every request with a body
// containing the actor's hostname (so substrate's whoami-style assertion works).
const http = require('http');
const os = require('os');

const PORT = 9222;
http.createServer((req, res) => {
  const body = 'Hostname: ' + os.hostname() + '\n';
  res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}).listen(PORT, '0.0.0.0', () => {
  console.log('control server listening on :' + PORT);
});
