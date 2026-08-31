# AI Assistant Instructions

<!-- appkit-instructions-start -->
## Databricks AppKit

This project uses Databricks AppKit packages. For AI assistant guidance on using these packages, refer to:

- **@databricks/appkit** (Backend SDK): [./node_modules/@databricks/appkit/CLAUDE.md](./node_modules/@databricks/appkit/CLAUDE.md)
- **@databricks/appkit-ui** (UI Integration, Charts, Tables, SSE, and more.): [./node_modules/@databricks/appkit-ui/CLAUDE.md](./node_modules/@databricks/appkit-ui/CLAUDE.md)

### Node.js

**Requires Node 24+.** The `tsdown`/`rolldown` bundler uses `styleText` from `node:util`, which landed in Node 20.12. Node 20.11.1 fails with `SyntaxError: The requested module 'node:util' does not provide an export named 'styleText'`.

Node 24 is installed at `C:\Users\Windows 10\node-v24.10.0-win-x64\` and is in the User PATH. If `npm` is not found in a new shell, ensure the PATH is set before running commands.

### Databricks Skills

For enhanced AI assistance with Databricks CLI operations, authentication, data exploration, and app development, install the Databricks skills:

```bash
databricks aitools install
```
<!-- appkit-instructions-end -->
