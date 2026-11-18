#ifndef HYDRA_INTERNAL_H
#define HYDRA_INTERNAL_H

#include "hydra_session.h"

#include <freerdp/client.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/dvc.h>
#include <winpr/synch.h>

#include <pthread.h>

struct HydraSession
{
	freerdp* instance;
	rdpContext* context;
	HANDLE thread;
	pthread_mutex_t lock;
	HydraCallbacks callbacks;
	void* user;
	char* password;
	char* gateway_password;
	char* access_token;
	char* refresh_token;
	int width;
	int height;
	int scale_percent;
	int pending_resize;
	int disp_ready;
	/* Last layout actually handed to the server. 0 until the first send. */
	int sent_width;
	int sent_height;
	int sent_scale;
	/* FreeRDP timer id; 0 when none is armed. */
	uint64_t resize_timer;
	char* connect_error;
	char auth_detail[320];
	IWTSVirtualChannel* hydra_channel;
	DispClientContext* disp;
	RdpgfxClientContext* gfx;
	int gfx_attached;
	int gfx_init_attempted;
	CliprdrClientContext* cliprdr;
	char* clipboard_utf8;
	int clipboard_ready;
	int running;
	int needs_credentials;
};

typedef struct
{
	rdpClientContext common;
	struct HydraSession* session;
} HydraContext;

void hydra_clipboard_attach(HydraSession* session, CliprdrClientContext* cliprdr);
void hydra_clipboard_detach(HydraSession* session);
void hydra_channels_prepare(void);
void hydra_channels_set_extra(const char* text);

#endif
