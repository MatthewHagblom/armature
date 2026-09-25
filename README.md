<!--
Keep this document short & concise,
linking to external resources instead of including content in-line.
See 'release/text/readme.html' for the end user read-me.
-->

Armature
========

An unofficial, LLM-powered native AArch64 (ARM64) Linux port based on
[Blender](https://www.blender.org)'s open source code, with NVIDIA CUDA and OptiX rendering in
Cycles. Blender doesn't publish Linux AArch64 builds or the precompiled libraries needed to make
one, so this repository includes a script that builds everything from source in one go:

```sh
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/MatthewHagblom/armature.git
cd armature
./build_linux_arm64.sh
```

Built and tested on an NVIDIA DGX Spark (GB10) running Ubuntu 24.04. See
[ARM64_LINUX_SUPPORT.md](ARM64_LINUX_SUPPORT.md) for requirements, the tested system, what was
changed and how the port is maintained.

**This is an LLM-powered port.** Its code changes, build script and documentation were written
by Claude, an AI model made by Anthropic, working in Claude Code. The repository owner set the
goals, tested the builds by hand and decided what to publish, but didn't write the changes or
review them line by line. Every change is built and tested on that system before it is
published, and each commit names the model that made it in its `Patched-and-ported-by:` line.

Armature is not affiliated with or endorsed by the Blender Foundation. Please don't report
problems with this port to the Blender project.

*Ported by Claude Opus 5.5 (Anthropic).*

---

*The rest of this file is Blender's own README.*

Blender
=======

Blender is the free and open source 3D creation suite.
It supports the entirety of the 3D pipeline—modeling, rigging, animation, simulation, rendering, compositing,
motion tracking and video editing.

![Blender screenshot](https://code.blender.org/wp-content/uploads/2018/12/springrg.jpg "Blender screenshot")

Project Pages
-------------

- [Main Website](https://www.blender.org)
- [Reference Manual](https://docs.blender.org/manual/en/latest/index.html)
- [User Community](https://www.blender.org/community/)

Development
-----------

- [Build Instructions](https://developer.blender.org/docs/handbook/building_blender/)
- [Code Review & Bug Tracker](https://projects.blender.org)
- [Developer Forum](https://devtalk.blender.org)
- [Developer Documentation](https://developer.blender.org/docs/)


License
-------

Blender as a whole is licensed under the GNU General Public License, Version 3.
Individual files may have a different but compatible license.

See [blender.org/about/license](https://www.blender.org/about/license) for details.
