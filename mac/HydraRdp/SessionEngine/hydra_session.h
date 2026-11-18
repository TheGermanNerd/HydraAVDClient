#ifndef HYDRA_SESSION_H
#define HYDRA_SESSION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*HydraFrameFn)(void* user, const uint8_t* pixels, int width, int height, int stride);
typedef void (*HydraStateFn)(void* user, int connected, const char* message);
typedef void (*HydraClipboardFn)(void* user, const char* utf8);
typedef void (*HydraChannelDataFn)(void* user, const uint8_t* data, int length);
typedef void (*HydraChannelClosedFn)(void* user);
/* Opens the authorize URL and returns a malloc'd callback URL, or NULL if cancelled. */
typedef char* (*HydraAuthorizeFn)(void* user, const char* url);
/* A connected session has ended. Must return without waiting on the UI thread. */
typedef void (*HydraEndedFn)(void* user);

typedef struct HydraCallbacks {
	HydraFrameFn frame;
	HydraStateFn state;
	HydraClipboardFn clipboard;
	HydraChannelDataFn channel_data;
	HydraChannelClosedFn channel_closed;
	HydraAuthorizeFn authorize;
	HydraEndedFn ended;
} HydraCallbacks;

typedef struct HydraSession HydraSession;

/* argv is copied. rdp_text, passwords, and access_token are copied and never logged.
 * extra_channels is "echo\\tNAME\\n" or "library\\tNAME\\tPATH\\n" lines. */
HydraSession* hydra_session_create(int argc, char** argv, const char* rdp_text, const char* password,
                                    const char* gateway_password, const char* access_token,
                                    const char* refresh_token, const char* extra_channels, int width,
                                    int height, const HydraCallbacks* callbacks, void* user);

void hydra_session_start(HydraSession* session);
void hydra_session_stop(HydraSession* session);
void hydra_session_destroy(HydraSession* session);

void hydra_session_key(HydraSession* session, int apple_keycode, int down, unsigned int unicode);
void hydra_session_mouse(HydraSession* session, int x, int y, int button, int down);
void hydra_session_wheel(HydraSession* session, int x, int y, int delta);
void hydra_session_resize(HydraSession* session, int width, int height, int scale_percent);
void hydra_session_set_clipboard(HydraSession* session, const char* utf8);
int hydra_session_channel_write(HydraSession* session, const uint8_t* data, int length);
void hydra_session_channel_close(HydraSession* session);

#ifdef __cplusplus
}
#endif

#endif
