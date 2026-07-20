## What this changes

A short description of the change and the *why*.

## Interop impact

Does this touch the wire format (fragment headers, encoding), the companion frame
codec, or interface behavior? If so, how was compatibility with the Python
`RNS_Over_Meshcore` driver verified?

## Checklist

- [ ] `swift test` passes (no regressions)
- [ ] New behavior is covered by tests (failing-test-first where practical)
- [ ] Wire-level changes checked against the Python reference / `MeshCoreWireParityTests`
- [ ] Docs updated if public API or config changed
