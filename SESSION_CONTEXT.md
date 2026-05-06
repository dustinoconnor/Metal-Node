# MetalNode Session Context

## Project Identity
- Workspace path: local checkout of the `MetalNode` repository.
- Xcode project/target name: `MetalNode`
- App display/product name: `Metal Composer`
- Bundle identifier: `com.dust.MetalNode`

## What This Project Is
- A macOS SwiftUI + Metal app for building and previewing node-based visual/shader graphs.
- The codebase includes a node canvas, shader preview, ISF parsing/translation, code editor windows, export support, audio-reactive input, and MIDI/output utilities.

## Important Clarifications
- The project folder/repo is `MetalNode`.
- The app users see is `Metal Composer`.
- A stray nested Git repo folder named `Metal Composer ` was removed on April 8, 2026 because it was accidental and did not contain the real app source.
- The main local Git repo is the one at the workspace root.

## Working Style
- Prefer working locally/offline first.
- Keep GitHub optional; do not depend on PR reviews to keep moving.
- The user manually tests node behavior, so the workflow can stay lightweight.

## Session Notes
- The user wants to continue from existing project context without having to re-explain the app every time a chat resets.
- If context is missing in a future session, read this file first, then inspect recent changes in the repo.
- Metal fragment persistence was fixed on April 12, 2026 by saving/restoring current fragment uniform values instead of letting preset metadata defaults win on reopen.
- Metal fragment deletion was beachballing after that persistence work. The important lesson: immediate fragment reselection/editor sync right after deleting a fragment can freeze the app.
- Safe delete behavior as of April 12, 2026: delete the fragment first, clear selection immediately, then reselect a safe fallback node on the next runloop tick. Current fallback lands on the attached render node or another safe node, and this avoids the beachball.
- On April 20, 2026, 3D architecture started moving from direct shader-only nodes toward a real `scene3DSignal` pipeline. `3D Primitive`, `3D Text`, `3D Model`, and `3D Light` now expose `Scene` outputs, there is a real downstream `3D Transform`, and a new `3D Render` node combines scene inputs back into a shader/renderable output.
- Important follow-up direction: long-term 3D work should prefer scene/object-style composition first, then render later. That architecture is intended to support downstream transforms, future camera/light composition, and later physics / procedural scene features better than the old direct-to-shader-only approach.

## Next Session Bootstrap
1. Read this file.
2. Check `git status --short --branch`.
3. Ask what feature or node behavior we were changing most recently only if the current work is not obvious from local changes.
