# Figma URL Parser — Format Handling

Parsing logic for extracting file key, node ID, and branch from Figma URLs.

## Supported URL Formats

| Format | Example | Extracted Fields |
|--------|---------|-----------------|
| Design URL | `https://www.figma.com/design/abc123/ProjectName` | file_key: abc123 |
| Design with node | `https://www.figma.com/design/abc123/Name?node-id=1-3` | file_key: abc123, node_id: 1:3 |
| File URL (legacy) | `https://www.figma.com/file/abc123/Name` | file_key: abc123 |
| Branch URL | `https://www.figma.com/design/abc123/Name?node-id=1-3&branch-name=dev` | file_key: abc123, node_id: 1:3, branch: dev |
| Dev mode | `https://www.figma.com/design/abc123/Name?node-id=1-3&mode=dev` | file_key: abc123, node_id: 1:3 |

## Parsing Algorithm

```
FIGMA_URL_PATTERN = /^https:\/\/www\.figma\.com\/(design|file)\/([A-Za-z0-9]+)(\/[^?]*)?(\?.*)?$/

function parseFigmaUrl(url):
  match = FIGMA_URL_PATTERN.exec(url)
  if not match:
    return { valid: false, error: "Invalid Figma URL format" }

  file_key = match[2]     // Alphanumeric file identifier
  query = parseQueryString(match[4])

  node_id = null
  if query["node-id"]:
    // Figma uses hyphens in URLs but colons in API
    node_id = query["node-id"].replace("-", ":")

  branch_name = query["branch-name"] ?? null

  return {
    valid: true,
    file_key: file_key,
    node_id: node_id,
    branch_name: branch_name,
    url_type: match[1],     // "design" or "file"
    original_url: url
  }
```

## Node ID Format

```
Figma internal: "1:3" (colon-separated)
Figma URL:      "1-3" (hyphen-separated)

Conversion:
  URL → API: replace("-", ":")
  API → URL: replace(":", "-")
```

## Constructing MCP Tool URLs

When calling Figma MCP tools, use the original URL format:

```
figma_fetch_design(url="https://www.figma.com/design/{file_key}/{name}?node-id={node_id_hyphen}")
figma_inspect_node(url="https://www.figma.com/design/{file_key}/{name}?node-id={node_id_hyphen}")
figma_list_components(url="https://www.figma.com/design/{file_key}/{name}")
```

## Official MCP Parameter Format

The Official Figma MCP tools use `fileKey` + `nodeId` as separate parameters instead of full URLs.

```
// Official MCP tools — separate fileKey and nodeId params
mcp__plugin_figma_figma__get_design_context(fileKey, nodeId)
mcp__plugin_figma_figma__get_metadata(fileKey)
mcp__plugin_figma_figma__get_code_connect_map(fileKey, nodeIds)
mcp__plugin_figma_figma__get_variable_defs(fileKey)
```

### Node ID Format Difference

```
Rune MCP (URL parameter): "1-3"  (hyphen-separated — matches Figma URL ?node-id= format)
Official MCP (parameter):  "1:3"  (colon-separated — matches Figma internal API format)

The parseFigmaUrl() function already converts URL hyphens to colons in the node_id field.
So parsedUrl.node_id is always in colon format ("1:3") — ready for Official MCP directly.
```

### `convertToOfficialParams(parsedUrl)` Helper

```
function convertToOfficialParams(parsedUrl):
  // parsedUrl is the return value of parseFigmaUrl(url)
  // parsedUrl.node_id is already colon-separated (e.g. "1:3")

  if not parsedUrl.valid:
    throw Error("Cannot convert invalid parsed URL to Official MCP params")

  fileKey = parsedUrl.file_key   // Extracted from URL path: /design/{fileKey}/...
  nodeId = parsedUrl.node_id     // Already colon format; null if not in URL

  return {
    fileKey: fileKey,             // Used as-is for all Official MCP tools
    nodeId: nodeId,               // "1:3" or null — check before passing
    nodeIds: nodeId ? [nodeId] : []  // Array form for get_code_connect_map
  }

// Usage
parsed = parseFigmaUrl("https://www.figma.com/design/abc123/Name?node-id=1-3")
params = convertToOfficialParams(parsed)
// params.fileKey = "abc123"
// params.nodeId  = "1:3"
// params.nodeIds = ["1:3"]
```

## Validation Rules

```
1. URL must start with https://www.figma.com/
2. Path must be /design/ or /file/ followed by alphanumeric file key
3. File key must be alphanumeric only [A-Za-z0-9]
4. Node ID (if present) must match /^\d+-\d+$/ format
5. Branch name (if present) must be URL-encoded string
6. Reject URLs with path traversal (../, %2e%2e)
```

## Error Handling

| Input | Error | Action |
|-------|-------|--------|
| Empty/null URL | "No Figma URL provided" | AskUserQuestion for URL |
| Non-Figma URL | "URL is not a Figma URL" | AskUserQuestion for correct URL |
| Missing file key | "Cannot extract file key from URL" | Show expected format |
| Invalid node ID | "Invalid node-id format: {value}" | Warn, attempt without node scoping |
| Prototype URL | "Prototype URLs not supported" | Ask for design/file URL |

## Security Considerations

```
- Validate URL format BEFORE passing to MCP tools
- Never interpolate URL parts into shell commands
- File keys are opaque — do not try to decode or modify them
- Node IDs are numeric with separator — reject non-numeric content
- Branch names must be URL-decoded safely
```

## Cross-References

- [phase1-design-extraction.md](phase1-design-extraction.md) — Uses parsed URL for extraction
- [vsm-spec.md](vsm-spec.md) — Records parsed URL in VSM metadata
