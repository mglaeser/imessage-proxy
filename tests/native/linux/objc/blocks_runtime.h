// GNUstep's Foundation headers include <objc/blocks_runtime.h>, a header that
// only libobjc2 ships. A Linux box that has the Debian blocks runtime but not
// libobjc2 on its include path fails the very first #import in src/ with a
// missing-header error that says nothing about the real cause, so this file
// forwards to the header the blocks runtime actually installs and keeps that
// packaging difference out of everything else here.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

#include <Block.h>
