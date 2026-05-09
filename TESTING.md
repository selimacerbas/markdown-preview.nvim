# Testing

## Running Tests

```bash
for f in tests/*_test.lua; do nvim --headless -c "set rtp+=." -c "luafile $f" -c "qa!"; done
```

## Test Structure

- `tests/host_config_test.lua` - Config defaults, overrides, module signatures
- `tests/lock_test.lua` - Lock file semantics (PID liveness, write/read/remove, stale lock detection)

## Notes

- Tests mock `live-server.nvim` to isolate plugin logic from server lifecycle
