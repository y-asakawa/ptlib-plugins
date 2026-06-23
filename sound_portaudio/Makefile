# Makefile for PortAudio sound plugin
#
# PortAudio sound driver for PTLib
#

PLUGIN_NAME    = portaudio
PLUGIN_FAMILY  = device/sound

# PortAudio flags from pkg-config
PORTAUDIO_CFLAGS  = $(shell pkg-config --cflags portaudio-2.0 2>/dev/null || echo "-I/opt/homebrew/include")
PORTAUDIO_LIBS    = $(shell pkg-config --libs portaudio-2.0 2>/dev/null || echo "-L/opt/homebrew/lib -lportaudio")

STDCCFLAGS += $(PORTAUDIO_CFLAGS)
PLUGIN_LIBS     = $(PORTAUDIO_LIBS)
PLUGIN_SOURCES  = sound_portaudio.cxx

# macOS requires -bundle for loadable plugins
ifeq ($(shell uname),Darwin)
LDSOPTS = -bundle -undefined dynamic_lookup
endif

PTLIB_MAKE_DIR ?= ../../make

include $(PTLIB_MAKE_DIR)/plugins.mak
