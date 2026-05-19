const http = require("http");

function add(a, b) {
  return a + b;
}

function multiply(a, b) {
  return a * b;
}

if (require.main === module) {
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", result: add(1, 2) }));
  });

  const port = process.env.PORT || 3000;
  server.listen(port, () => {
    console.log(`server listening on port ${port}`);
  });
}

module.exports = { add, multiply };
