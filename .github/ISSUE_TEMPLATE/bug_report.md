---
name: Bug report
about: Report incorrect behavior, a crash, or a MeshCore/Python interop mismatch
labels: bug
---

**What happened**
A clear description of the bug.

**Expected behavior**
What you expected instead. If this is an interop bug, what does the Python
`RNS_Over_Meshcore` driver do on the same MeshCore channel?

**Reproduction**
Steps, a failing test, or a packet/frame capture. The more concrete, the better.
Which interface — `MeshCoreDynamicInterface`, `MeshCoreChannelInterface`, or
`MeshCoreContactInterface`?

**Environment**
- RNSOverMeshCore version / commit:
- ReticulumSwift version:
- Transport: TCP / BLE / serial, and the MeshCore firmware version:
- Platform (iOS / macOS / …) and Swift / Xcode version:
- Talking to a Python node? Which `RNS_Over_Meshcore` / RNS version?

**Logs**
Relevant output.
