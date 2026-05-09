# Testing

## Running Tests

```bash
nvim --headless -c "set rtp+=." -c "luafile tests/host_config_test.lua" -c "qa!"
```

## Test Structure

- `tests/host_config_test.lua` - Tests for host configuration feature

## Notes

- Tests mock the `live-server.nvim` dependency since it may not be available in all environments
- The test harness is minimal and focuses on interface/signature verification
