# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/ry-ops/afm-studio/security/advisories/new).
Don't open a public issue for them.

Include what you found, how to reproduce it, and which version (`afm --version`) you tested.
You should get a reply within a week.

## Supported versions

Only the latest commit on `main` gets security fixes.

## What AFM Studio protects

The README's [Security and privacy](README.md#security-and-privacy) section describes what leaves
your Mac, what the local API server and the MCP server can reach, and which files are off limits.
Reports that get around any of those protections are in scope. Examples:

- reading a blocked file, or a file outside the allowed folders, through MCP or the model's tools
- making `fetch_url` reach a local or private address without `AFM_FETCH_ALLOW_PRIVATE=1`
- driving the local API server from a web page
- crashing the app or the servers with a crafted request
- an integration writing to an outside service, or reading credentials while it's turned off
