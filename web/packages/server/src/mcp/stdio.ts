import { runStdioMCPServer } from '../mcp-stdio.js';

runStdioMCPServer().catch((err) => {
  process.stderr.write(
    `Charkle MCP stdio error: ${err instanceof Error ? err.message : String(err)}\n`,
  );
  process.exit(1);
});
