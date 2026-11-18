#include "hydra_internal.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/settings.h>

#include <winpr/stream.h>

#define HYDRA_EXTRA_LIMIT 32

typedef struct
{
	GENERIC_DYNVC_PLUGIN base;
	HydraSession* session;
} HydraPlugin;

typedef struct
{
	char name[128];
	int library;
	char path[1024];
} HydraExtra;

static HydraExtra g_extra[HYDRA_EXTRA_LIMIT];
static int g_extra_count = 0;
static void* g_libraries[HYDRA_EXTRA_LIMIT];
static int g_library_count = 0;

static UINT hydra_on_data(IWTSVirtualChannelCallback* callback, wStream* data)
{
	GENERIC_CHANNEL_CALLBACK* channel = (GENERIC_CHANNEL_CALLBACK*)callback;
	HydraPlugin* plugin = (HydraPlugin*)channel->plugin;
	const BYTE* buffer = Stream_ConstPointer(data);
	size_t size = Stream_GetRemainingLength(data);
	HydraSession* session = plugin ? plugin->session : NULL;
	if (!session)
		return CHANNEL_RC_OK;
	if (size > 16777216)
		return CHANNEL_RC_OK;
	pthread_mutex_lock(&session->lock);
	if (!session->hydra_channel)
		session->hydra_channel = channel->channel;
	pthread_mutex_unlock(&session->lock);
	if (session->callbacks.channel_data)
		session->callbacks.channel_data(session->user, buffer, (int)size);
	return CHANNEL_RC_OK;
}

static UINT hydra_on_open(IWTSVirtualChannelCallback* callback)
{
	GENERIC_CHANNEL_CALLBACK* channel = (GENERIC_CHANNEL_CALLBACK*)callback;
	HydraPlugin* plugin = (HydraPlugin*)channel->plugin;
	if (plugin && plugin->session)
	{
		pthread_mutex_lock(&plugin->session->lock);
		plugin->session->hydra_channel = channel->channel;
		pthread_mutex_unlock(&plugin->session->lock);
	}
	return CHANNEL_RC_OK;
}

static UINT hydra_on_close(IWTSVirtualChannelCallback* callback)
{
	GENERIC_CHANNEL_CALLBACK* channel = (GENERIC_CHANNEL_CALLBACK*)callback;
	HydraPlugin* plugin = (HydraPlugin*)channel->plugin;
	if (plugin && plugin->session)
	{
		pthread_mutex_lock(&plugin->session->lock);
		if (plugin->session->hydra_channel == channel->channel)
			plugin->session->hydra_channel = NULL;
		pthread_mutex_unlock(&plugin->session->lock);
	}
	free(channel);
	return CHANNEL_RC_OK;
}

static UINT hydra_plugin_init(GENERIC_DYNVC_PLUGIN* plugin, rdpContext* context, rdpSettings* settings)
{
	HydraPlugin* hydra = (HydraPlugin*)plugin;
	(void)settings;
	hydra->session = context ? ((HydraContext*)context)->session : NULL;
	return CHANNEL_RC_OK;
}

static const IWTSVirtualChannelCallback hydra_callbacks = { hydra_on_data, hydra_on_open, hydra_on_close,
	                                                       NULL };

static UINT hydra_DVCPluginEntry(IDRDYNVC_ENTRY_POINTS* entry)
{
	return freerdp_generic_DVCPluginEntry(entry, "hydra.channel", "HYDAGX01", sizeof(HydraPlugin),
	                                      sizeof(GENERIC_CHANNEL_CALLBACK), &hydra_callbacks,
	                                      hydra_plugin_init, NULL);
}

static UINT echo_on_data(IWTSVirtualChannelCallback* callback, wStream* data)
{
	GENERIC_CHANNEL_CALLBACK* channel = (GENERIC_CHANNEL_CALLBACK*)callback;
	const BYTE* buffer = Stream_ConstPointer(data);
	size_t size = Stream_GetRemainingLength(data);
	if (!channel->channel || !channel->channel->Write || size > UINT32_MAX)
		return CHANNEL_RC_OK;
	return channel->channel->Write(channel->channel, (ULONG)size, buffer, NULL);
}

static UINT echo_on_close(IWTSVirtualChannelCallback* callback)
{
	free(callback);
	return CHANNEL_RC_OK;
}

static const IWTSVirtualChannelCallback echo_callbacks = { echo_on_data, NULL, echo_on_close, NULL };

static UINT echo_DVCPluginEntry(IDRDYNVC_ENTRY_POINTS* entry)
{
	const ADDIN_ARGV* args = entry->GetPluginData(entry);
	const char* name = (args && args->argc > 0 && args->argv && args->argv[0]) ? args->argv[0] : "ECHO";
	return freerdp_generic_DVCPluginEntry(entry, "hydra.echo", name, sizeof(GENERIC_DYNVC_PLUGIN),
	                                      sizeof(GENERIC_CHANNEL_CALLBACK), &echo_callbacks, NULL, NULL);
}

static PVIRTUALCHANNELENTRY load_library_entry(const char* path)
{
	void* handle = NULL;
	void* symbol = NULL;
	if (!path || !path[0] || g_library_count >= HYDRA_EXTRA_LIMIT)
		return NULL;
	handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!handle)
		return NULL;
	symbol = dlsym(handle, "DVCPluginEntry");
	if (!symbol)
	{
		dlclose(handle);
		return NULL;
	}
	g_libraries[g_library_count++] = handle;
	return (PVIRTUALCHANNELENTRY)symbol;
}

static PVIRTUALCHANNELENTRY hydra_provider(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags)
{
	PVIRTUALCHANNELENTRY entry = freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
	int index = 0;
	if (entry)
		return entry;
	if (!name || !(flags & FREERDP_ADDIN_CHANNEL_DYNAMIC))
		return NULL;
	if (strcmp(name, "HYDAGX01") == 0)
		return (PVIRTUALCHANNELENTRY)hydra_DVCPluginEntry;
	for (index = 0; index < g_extra_count; index++)
	{
		if (strcmp(g_extra[index].name, name) != 0)
			continue;
		if (g_extra[index].library)
			return load_library_entry(g_extra[index].path);
		return (PVIRTUALCHANNELENTRY)echo_DVCPluginEntry;
	}
	return NULL;
}

void hydra_channels_prepare(void)
{
	freerdp_register_addin_provider(hydra_provider, 0);
}

void hydra_channels_set_extra(const char* text)
{
	const char* cursor = text;
	g_extra_count = 0;
	if (!text)
		return;
	while (*cursor && g_extra_count < HYDRA_EXTRA_LIMIT)
	{
		char line[1200];
		const char* end = strchr(cursor, '\n');
		size_t length = end ? (size_t)(end - cursor) : strlen(cursor);
		char* kind = NULL;
		char* name = NULL;
		char* path = NULL;
		if (length >= sizeof(line))
			length = sizeof(line) - 1;
		memcpy(line, cursor, length);
		line[length] = '\0';
		cursor = end ? end + 1 : cursor + length;
		kind = line;
		name = strchr(line, '\t');
		if (!name)
			continue;
		*name++ = '\0';
		path = strchr(name, '\t');
		if (path)
			*path++ = '\0';
		if (!name[0])
			continue;
		snprintf(g_extra[g_extra_count].name, sizeof(g_extra[g_extra_count].name), "%s", name);
		g_extra[g_extra_count].library = strcmp(kind, "library") == 0;
		g_extra[g_extra_count].path[0] = '\0';
		if (path)
			snprintf(g_extra[g_extra_count].path, sizeof(g_extra[g_extra_count].path), "%s", path);
		g_extra_count++;
	}
}
