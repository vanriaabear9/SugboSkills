const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const port = Number(process.env.PORT) || 5173;
const staticFiles = new Map([
  ["/", { file: "index.html", type: "text/html; charset=utf-8" }],
  ["/index.html", { file: "index.html", type: "text/html; charset=utf-8" }],
  ["/supabase-config.js", { file: "supabase-config.js", type: "text/javascript; charset=utf-8" }]
]);

const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, `http://${request.headers.host}`).pathname;

  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { Allow: "GET, HEAD" });
    response.end("Method Not Allowed");
    return;
  }

  const file = staticFiles.get(pathname);
  if (!file) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not Found");
    return;
  }

  fs.readFile(path.join(__dirname, file.file), (error, content) => {
    if (error) {
      console.error(`Could not read ${file.file}:`, error);
      response.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
      response.end("Could not load the prototype.");
      return;
    }

    response.writeHead(200, {
      "Content-Type": file.type,
      "Content-Length": content.length
    });
    response.end(request.method === "HEAD" ? undefined : content);
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`SugboSkills prototype running at http://localhost:${port}`);
});
