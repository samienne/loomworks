# loomworks

The editor-independent core of loomworks: the `lw` command-line tool and the
workspace daemon. loomworks turns a project's build variants into resolved,
buildable profiles and drives configure, build, run, test and clean through
one consistent interface.

The Neovim integration lives in
[loomworks.nvim](https://github.com/samienne/loomworks.nvim), which talks to
this daemon over its protocol.

**Status:** work in progress. The code is being moved here from
loomworks.nvim.
