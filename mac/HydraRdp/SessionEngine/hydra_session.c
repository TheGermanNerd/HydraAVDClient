#include "hydra_internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/constants.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/timer.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/addin.h>
#include <freerdp/utils/aad.h>
#include <freerdp/utils/http.h>

#include <winpr/crt.h>
#include <winpr/input.h>
#include <winpr/json.h>
#include <winpr/string.h>
#include <winpr/synch.h>

static HydraSession* g_creating = NULL;

/* Windows drops a monitor layout that arrives with, or immediately after, the caps PDU. */
#define HYDRA_RESIZE_DELAY_NS 500000000ull

static void hydra_on_channel_connected(void* context, const ChannelConnectedEventArgs* event);
static void hydra_on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* event);
static void hydra_clamp_desktop(int* width, int* height);
static void hydra_schedule_resize_locked(HydraSession* session);
static void hydra_send_pending_resize(HydraSession* session);
static uint64_t hydra_resize_timer(rdpContext* context, void* userdata, FreeRDP_TimerID timerID,
                                   uint64_t timestamp, uint64_t interval);

static HydraSession* session_from(freerdp* instance)
{
	if (!instance || !instance->context)
		return NULL;
	return ((HydraContext*)instance->context)->session;
}

static void report(HydraSession* session, int connected, const char* message)
{
	if (!session || !session->callbacks.state)
		return;
	session->callbacks.state(session->user, connected, message ? message : "");
}

static void notify_ended(HydraSession* session)
{
	if (!session || !session->callbacks.ended)
		return;
	session->callbacks.ended(session->user);
}

static BOOL hydra_begin_paint(rdpContext* context)
{
	rdpGdi* gdi = context ? context->gdi : NULL;
	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd ||
	    !gdi->primary->hdc->hwnd->invalid)
		return TRUE;
	gdi->primary->hdc->hwnd->invalid->null = TRUE;
	return TRUE;
}

static BOOL hydra_end_paint(rdpContext* context)
{
	HydraSession* session = context ? ((HydraContext*)context)->session : NULL;
	rdpGdi* gdi = context ? context->gdi : NULL;
	if (!session || !gdi || !gdi->primary_buffer || !gdi->primary || !gdi->primary->hdc ||
	    !gdi->primary->hdc->hwnd || !gdi->primary->hdc->hwnd->invalid)
		return TRUE;
	if (gdi->primary->hdc->hwnd->invalid->null)
		return TRUE;
	if (gdi->width <= 0 || gdi->height <= 0 || gdi->stride == 0)
		return TRUE;
	if (session->callbacks.frame)
	{
		session->callbacks.frame(session->user, gdi->primary_buffer, gdi->width, gdi->height,
		                         (int)gdi->stride);
	}
	return TRUE;
}

static BOOL hydra_desktop_resize(rdpContext* context)
{
	HydraSession* session = context ? ((HydraContext*)context)->session : NULL;
	UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
	UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
	if (!gdi_resize(context->gdi, width, height))
		return FALSE;
	if (session)
		report(session, 1, "Desktop size changed");
	return TRUE;
}

static BOOL hydra_pre_connect(freerdp* instance)
{
	HydraSession* session = session_from(instance);
	rdpSettings* settings = instance->context->settings;
	hydra_channels_prepare();
	freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE);
	freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
	freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH);
	freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH);
	if (PubSub_SubscribeChannelConnected(instance->context->pubSub, hydra_on_channel_connected) < 0)
		return FALSE;
	if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub, hydra_on_channel_disconnected) <
	    0)
		return FALSE;
	if (session)
	{
		UINT32 desktop_scale = 100;
		UINT32 device_scale = 100;
		pthread_mutex_lock(&session->lock);
		if (session->width > 0 && session->height > 0)
		{
			freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (UINT32)session->width);
			freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (UINT32)session->height);
		}
		if (session->scale_percent >= 200)
		{
			desktop_scale = 200;
			device_scale = 180;
		}
		freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, desktop_scale);
		freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, device_scale);
		/* The connection request itself carries this size, so it is not still pending. */
		session->sent_width = session->width;
		session->sent_height = session->height;
		session->sent_scale = session->scale_percent;
		session->pending_resize = 0;
		pthread_mutex_unlock(&session->lock);
		report(session, 0, "Connecting");
	}
	return TRUE;
}

static BOOL hydra_attach_graphics(HydraSession* session)
{
	rdpGdi* gdi = NULL;
	rdpUpdate* update = NULL;
	if (!session || !session->gfx || !session->context || !session->context->gdi)
		return FALSE;
	if (session->gfx_attached)
		return TRUE;
	if (session->gfx_init_attempted)
		return FALSE;
	session->gfx_init_attempted = 1;
	gdi = session->context->gdi;
	if (!gdi_graphics_pipeline_init(gdi, session->gfx))
		return FALSE;
	session->gfx_attached = 1;
	update = session->context->update;
	if (update && update->SuppressOutput)
	{
		gdi->suppressOutput = TRUE;
		gdi_send_suppress_output(gdi, FALSE);
	}
	return TRUE;
}

static void hydra_clamp_desktop(int* width, int* height)
{
	if (!width || !height)
		return;
	if (*width < 200)
		*width = 200;
	if (*height < 200)
		*height = 200;
	if (*width > 8192)
		*width = 8192;
	if (*height > 8192)
		*height = 8192;
	*width &= ~1;
	*height &= ~1;
}

static void hydra_fill_layout(DISPLAY_CONTROL_MONITOR_LAYOUT* layout, int width, int height,
                              int scale_percent)
{
	UINT32 desktop = 100;
	UINT32 device = 100;
	ZeroMemory(layout, sizeof(*layout));
	layout->Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	layout->Width = (UINT32)width;
	layout->Height = (UINT32)height;
	layout->Orientation = ORIENTATION_LANDSCAPE;
	if (scale_percent >= 200)
	{
		desktop = 200;
		device = 180;
	}
	layout->DesktopScaleFactor = desktop;
	layout->DeviceScaleFactor = device;
	layout->PhysicalWidth = (UINT32)(width * 254 / 960);
	layout->PhysicalHeight = (UINT32)(height * 254 / 960);
	if (layout->PhysicalWidth < 10)
		layout->PhysicalWidth = 10;
	if (layout->PhysicalHeight < 10)
		layout->PhysicalHeight = 10;
	if (layout->PhysicalWidth > 10000)
		layout->PhysicalWidth = 10000;
	if (layout->PhysicalHeight > 10000)
		layout->PhysicalHeight = 10000;
}

/* Caller holds session->lock. A layout is sent only after display-control caps, and only
 * after a short delay: Windows ignores one that arrives immediately. */
static void hydra_schedule_resize_locked(HydraSession* session)
{
	if (!session->pending_resize || !session->disp_ready || !session->context)
		return;
	if (session->resize_timer != 0)
		return;
	session->resize_timer = freerdp_timer_add(session->context, HYDRA_RESIZE_DELAY_NS,
	                                          hydra_resize_timer, session, true);
}

static void hydra_send_pending_resize(HydraSession* session)
{
	DISPLAY_CONTROL_MONITOR_LAYOUT layout;
	DispClientContext* disp = NULL;
	int width = 0;
	int height = 0;
	int scale = 100;
	UINT result = CHANNEL_RC_OK;
	if (!session)
		return;
	pthread_mutex_lock(&session->lock);
	session->resize_timer = 0;
	if (!session->pending_resize || !session->disp_ready || !session->disp ||
	    !session->disp->SendMonitorLayout)
	{
		pthread_mutex_unlock(&session->lock);
		return;
	}
	if (session->width == session->sent_width && session->height == session->sent_height &&
	    session->scale_percent == session->sent_scale)
	{
		session->pending_resize = 0;
		pthread_mutex_unlock(&session->lock);
		return;
	}
	width = session->width;
	height = session->height;
	scale = session->scale_percent;
	disp = session->disp;
	hydra_fill_layout(&layout, width, height, scale);
	pthread_mutex_unlock(&session->lock);

	result = disp->SendMonitorLayout(disp, 1, &layout);

	pthread_mutex_lock(&session->lock);
	if (result == CHANNEL_RC_OK && session->width == width && session->height == height &&
	    session->scale_percent == scale)
	{
		session->pending_resize = 0;
		session->sent_width = width;
		session->sent_height = height;
		session->sent_scale = scale;
	}
	else if (session->pending_resize)
		hydra_schedule_resize_locked(session);
	pthread_mutex_unlock(&session->lock);
}

static uint64_t hydra_resize_timer(rdpContext* context, void* userdata, FreeRDP_TimerID timerID,
                                   uint64_t timestamp, uint64_t interval)
{
	(void)context;
	(void)timerID;
	(void)timestamp;
	(void)interval;
	hydra_send_pending_resize((HydraSession*)userdata);
	return 0;
}

static UINT hydra_display_caps(DispClientContext* disp, UINT32 maxNumMonitors,
                               UINT32 maxMonitorAreaFactorA, UINT32 maxMonitorAreaFactorB)
{
	HydraSession* session = disp ? (HydraSession*)disp->custom : NULL;
	(void)maxNumMonitors;
	(void)maxMonitorAreaFactorA;
	(void)maxMonitorAreaFactorB;
	if (!session)
		return CHANNEL_RC_OK;
	pthread_mutex_lock(&session->lock);
	session->disp_ready = 1;
	hydra_schedule_resize_locked(session);
	pthread_mutex_unlock(&session->lock);
	return CHANNEL_RC_OK;
}

static void hydra_on_channel_connected(void* context, const ChannelConnectedEventArgs* event)
{
	HydraContext* hydra = (HydraContext*)context;
	HydraSession* session = hydra ? hydra->session : NULL;
	if (!session || !event || !event->name)
		return;
	if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		hydra_clipboard_attach(session, (CliprdrClientContext*)event->pInterface);
	else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		DispClientContext* disp = (DispClientContext*)event->pInterface;
		pthread_mutex_lock(&session->lock);
		session->disp = disp;
		session->disp_ready = 0;
		if (disp)
		{
			disp->custom = session;
			disp->DisplayControlCaps = hydra_display_caps;
		}
		pthread_mutex_unlock(&session->lock);
	}
	else if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
	{
		session->gfx = (RdpgfxClientContext*)event->pInterface;
		if (session->context && session->context->gdi && !hydra_attach_graphics(session))
			report(session, 1, "Connected, but the picture decoder failed");
	}
	else
		freerdp_client_OnChannelConnectedEventHandler(context, event);
}

static void hydra_on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* event)
{
	HydraContext* hydra = (HydraContext*)context;
	HydraSession* session = hydra ? hydra->session : NULL;
	if (!session || !event || !event->name)
		return;
	if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		hydra_clipboard_detach(session);
	else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		pthread_mutex_lock(&session->lock);
		session->disp = NULL;
		session->disp_ready = 0;
		pthread_mutex_unlock(&session->lock);
	}
	else if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
	{
		if (session->gfx_attached && session->context && session->context->gdi && session->gfx)
			gdi_graphics_pipeline_uninit(session->context->gdi, session->gfx);
		session->gfx = NULL;
		session->gfx_attached = 0;
	}
	else
		freerdp_client_OnChannelDisconnectedEventHandler(context, event);
}

static BOOL hydra_post_connect(freerdp* instance)
{
	HydraSession* session = session_from(instance);
	if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
		return FALSE;
	instance->context->update->BeginPaint = hydra_begin_paint;
	instance->context->update->EndPaint = hydra_end_paint;
	instance->context->update->DesktopResize = hydra_desktop_resize;
	if (session)
	{
		if (session->gfx && !hydra_attach_graphics(session))
			report(session, 1, "Connected, but the picture decoder failed");
		else
			report(session, 1, "Connected");
	}
	return TRUE;
}

static void hydra_post_disconnect(freerdp* instance)
{
	HydraSession* session = NULL;
	if (!instance || !instance->context)
		return;
	session = session_from(instance);
	if (session && session->gfx_attached && instance->context->gdi && session->gfx)
	{
		gdi_graphics_pipeline_uninit(instance->context->gdi, session->gfx);
		session->gfx_attached = 0;
	}
	PubSub_UnsubscribeChannelConnected(instance->context->pubSub, hydra_on_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, hydra_on_channel_disconnected);
	gdi_free(instance);
}

static DWORD hydra_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                      const char* common_name, const char* subject, const char* issuer,
                                      const char* fingerprint, DWORD flags)
{
	(void)instance;
	(void)port;
	(void)subject;
	(void)issuer;
	(void)fingerprint;
	(void)flags;
	HydraSession* session = session_from(instance);
	if (session)
	{
		char message[256];
		snprintf(message, sizeof(message), "Accepted certificate for %s", host ? host : "server");
		report(session, 0, message);
	}
	return 2;
}

static DWORD hydra_verify_changed(freerdp* instance, const char* host, UINT16 port,
                                  const char* common_name, const char* subject, const char* issuer,
                                  const char* new_fingerprint, const char* old_subject,
                                  const char* old_issuer, const char* old_fingerprint, DWORD flags)
{
	(void)port;
	(void)common_name;
	(void)subject;
	(void)issuer;
	(void)new_fingerprint;
	(void)old_subject;
	(void)old_issuer;
	(void)old_fingerprint;
	(void)flags;
	return hydra_verify_certificate(instance, host, port, common_name, subject, issuer, new_fingerprint,
	                                flags);
}

static int text_missing(const char* value)
{
	return !value || !value[0];
}

static BOOL hydra_authenticate(freerdp* instance, char** username, char** password, char** domain,
                               rdp_auth_reason reason)
{
	HydraSession* session = session_from(instance);
	const char* secret = NULL;
	(void)domain;
	if (!session || !password)
		return TRUE;
	secret = (reason == GW_AUTH_HTTP || reason == GW_AUTH_RDG || reason == GW_AUTH_RPC)
	             ? session->gateway_password
	             : session->password;
	if (secret && secret[0] && (*password == NULL || (*password)[0] == '\0'))
	{
		free(*password);
		*password = _strdup(secret);
	}
	/* An NLA server resets the socket when the client sends an empty identity.
	 * FreeRDP reports that reset as a transport failure. */
	if (reason == AUTH_NLA &&
	    (text_missing(username ? *username : NULL) || text_missing(*password)))
	{
		session->needs_credentials = 1;
		return FALSE;
	}
	return TRUE;
}

static char* form_escape(const char* value)
{
	static const char hex[] = "0123456789ABCDEF";
	size_t length = 0;
	const unsigned char* cursor = NULL;
	char* out = NULL;
	char* write = NULL;
	if (!value)
		return NULL;
	for (cursor = (const unsigned char*)value; *cursor; cursor++)
	{
		unsigned char c = *cursor;
		if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' ||
		    c == '.' || c == '_' || c == '~')
			length++;
		else
			length += 3;
	}
	out = (char*)malloc(length + 1);
	if (!out)
		return NULL;
	write = out;
	for (cursor = (const unsigned char*)value; *cursor; cursor++)
	{
		unsigned char c = *cursor;
		if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' ||
		    c == '.' || c == '_' || c == '~')
			*write++ = (char)c;
		else
		{
			*write++ = '%';
			*write++ = hex[c >> 4];
			*write++ = hex[c & 15];
		}
	}
	*write = '\0';
	return out;
}

static void remember(HydraSession* session, const char* message)
{
	if (!session || !message)
		return;
	snprintf(session->auth_detail, sizeof(session->auth_detail), "%s", message);
	report(session, 0, message);
}

static const char* hydra_client_id(freerdp* instance)
{
	const char* client_id = NULL;
	if (instance && instance->context)
		client_id = freerdp_settings_get_string(instance->context->settings, FreeRDP_GatewayAvdClientID);
	if (!client_id || !client_id[0])
		return "a85cf173-4192-42f8-81fa-777a763e6e2c";
	return client_id;
}

static char* json_field(const char* text, const char* key)
{
	WINPR_JSON* root = NULL;
	WINPR_JSON* item = NULL;
	const char* value = NULL;
	char* copy = NULL;
	if (!text || !text[0] || !key)
		return NULL;
	root = WINPR_JSON_Parse(text);
	if (!root)
		return NULL;
	item = WINPR_JSON_GetObjectItemCaseSensitive(root, key);
	value = item ? WINPR_JSON_GetStringValue(item) : NULL;
	if (value && value[0])
		copy = _strdup(value);
	WINPR_JSON_Delete(root);
	return copy;
}

static void one_line(char* text)
{
	char* cursor = NULL;
	for (cursor = text; cursor && *cursor; cursor++)
	{
		if (*cursor == '\n' || *cursor == '\r' || *cursor == '\t')
			*cursor = ' ';
	}
}

static char* query_value(const char* url, const char* key)
{
	const char* query = NULL;
	const char* cursor = NULL;
	size_t key_length = 0;
	if (!url || !key)
		return NULL;
	query = strchr(url, '?');
	if (!query)
		return NULL;
	key_length = strlen(key);
	for (cursor = query + 1; *cursor;)
	{
		const char* next = strchr(cursor, '&');
		size_t length = next ? (size_t)(next - cursor) : strlen(cursor);
		if (length > key_length && strncmp(cursor, key, key_length) == 0 && cursor[key_length] == '=')
		{
			const char* start = cursor + key_length + 1;
			size_t value_length = length - key_length - 1;
			return winpr_str_url_decode(start, value_length);
		}
		if (!next)
			break;
		cursor = next + 1;
	}
	return NULL;
}

static BOOL post_token(freerdp* instance, const char* body, char** token, char* error, size_t error_size)
{
	const char* endpoint = NULL;
	long status = 0;
	BYTE* response = NULL;
	size_t length = 0;
	char* access = NULL;
	BOOL ok = FALSE;
	if (error && error_size > 0)
		error[0] = '\0';
	if (!instance || !instance->context || !body || !token)
		return FALSE;
	*token = NULL;
	endpoint = freerdp_utils_aad_get_wellknown_string(instance->context, AAD_WELLKNOWN_token_endpoint);
	if (!endpoint || !freerdp_http_request(endpoint, body, &status, &response, &length))
	{
		if (error && error_size > 0)
			snprintf(error, error_size, "Could not reach the desktop sign-in service.");
		free(response);
		return FALSE;
	}
	if (status == 200 && response)
	{
		access = json_field((const char*)response, "access_token");
		if (access)
		{
			*token = access;
			ok = TRUE;
		}
		else if (error && error_size > 0)
			snprintf(error, error_size, "The desktop sign-in response had no token.");
	}
	else if (error && error_size > 0)
	{
		char* description = response ? json_field((const char*)response, "error_description") : NULL;
		if (!description && response)
			description = json_field((const char*)response, "error");
		if (description)
		{
			one_line(description);
			snprintf(error, error_size, "Desktop sign-in was rejected: %.180s", description);
			free(description);
		}
		else
			snprintf(error, error_size, "Desktop sign-in was rejected (HTTP %ld).", status);
	}
	free(response);
	return ok;
}

static char* login_hint(freerdp* instance)
{
	const char* user = NULL;
	char* encoded = NULL;
	char* parameter = NULL;
	size_t length = 0;
	if (!instance || !instance->context)
		return _strdup("");
	user = freerdp_settings_get_string(instance->context->settings, FreeRDP_Username);
	if (!user || !strchr(user, '@') || strchr(user, '\\'))
		return _strdup("");
	encoded = winpr_str_url_encode(user, strlen(user));
	if (!encoded)
		return NULL;
	if (winpr_asprintf(&parameter, &length, "&login_hint=%s", encoded) < 0)
		parameter = NULL;
	free(encoded);
	return parameter;
}

static BOOL hydra_silent_aad_token(freerdp* instance, HydraSession* session, const char* scope,
                                   const char* req_cnf, char** token)
{
	const char* client_id = NULL;
	char* escaped_id = NULL;
	char* escaped_refresh = NULL;
	char* escaped_cnf = NULL;
	char* body = NULL;
	size_t body_length = 0;
	char error[240];
	BOOL ok = FALSE;
	if (!session->refresh_token || !session->refresh_token[0])
		return FALSE;
	client_id = hydra_client_id(instance);
	escaped_id = form_escape(client_id);
	escaped_refresh = form_escape(session->refresh_token);
	escaped_cnf = form_escape(req_cnf);
	if (!escaped_id || !escaped_refresh || !escaped_cnf)
		goto done;
	if (winpr_asprintf(&body, &body_length,
	                   "grant_type=refresh_token&client_id=%s&refresh_token=%s&scope=%s&req_cnf=%s",
	                   escaped_id, escaped_refresh, scope, escaped_cnf) < 0 ||
	    !body)
		goto done;
	ok = post_token(instance, body, token, error, sizeof(error));
done:
	free(escaped_id);
	free(escaped_refresh);
	free(escaped_cnf);
	free(body);
	return ok;
}

static BOOL hydra_interactive_aad_token(freerdp* instance, HydraSession* session, const char* scope,
                                        const char* req_cnf, char** token)
{
	const char* client_id = NULL;
	const char* endpoint = NULL;
	char state[40];
	char raw_redirect[256];
	char* escaped_redirect = NULL;
	char* hint = NULL;
	char* url = NULL;
	char* callback = NULL;
	char* code = NULL;
	char* returned_state = NULL;
	char* escaped_code = NULL;
	char* escaped_cnf = NULL;
	char* body = NULL;
	size_t length = 0;
	unsigned char random_bytes[16];
	size_t index = 0;
	char error[240];
	BOOL ok = FALSE;
	if (!session->callbacks.authorize)
	{
		remember(session, "Sign in again. The desktop needs a fresh Entra token.");
		return FALSE;
	}
	endpoint = freerdp_utils_aad_get_wellknown_string(instance->context,
	                                                  AAD_WELLKNOWN_authorization_endpoint);
	client_id = hydra_client_id(instance);
	if (!endpoint || !scope || !req_cnf)
	{
		remember(session, "Could not reach the desktop sign-in service.");
		return FALSE;
	}
	arc4random_buf(random_bytes, sizeof(random_bytes));
	for (index = 0; index < sizeof(random_bytes); index++)
		snprintf(state + index * 2, 3, "%02x", random_bytes[index]);
	snprintf(raw_redirect, sizeof(raw_redirect), "ms-appx-web://Microsoft.AAD.BrokerPlugin/%s", client_id);
	escaped_redirect = form_escape(raw_redirect);
	hint = login_hint(instance);
	if (!escaped_redirect || !hint)
		goto done;
	if (winpr_asprintf(&url, &length,
	                   "%s?client_id=%s&response_type=code&response_mode=query&redirect_uri=%s&scope=%s&state=%s%s",
	                   endpoint, client_id, escaped_redirect, scope, state, hint) < 0 ||
	    !url)
		goto done;
	report(session, 0, "Sign in to this desktop");
	callback = session->callbacks.authorize(session->user, url);
	if (!callback)
	{
		remember(session, "Desktop sign-in was cancelled.");
		goto done;
	}
	code = query_value(callback, "code");
	returned_state = query_value(callback, "state");
	if (!code || !returned_state || strcmp(returned_state, state) != 0)
	{
		char* description = query_value(callback, "error_description");
		if (!description)
			description = query_value(callback, "error");
		if (description)
		{
			one_line(description);
			snprintf(error, sizeof(error), "Desktop sign-in was rejected: %.180s", description);
			free(description);
		}
		else
			snprintf(error, sizeof(error), "Desktop sign-in did not return a code.");
		remember(session, error);
		goto done;
	}
	escaped_code = form_escape(code);
	escaped_cnf = form_escape(req_cnf);
	if (!escaped_code || !escaped_cnf)
		goto done;
	if (winpr_asprintf(&body, &length,
	                   "grant_type=authorization_code&code=%s&client_id=%s&scope=%s&redirect_uri=%s&req_cnf=%s",
	                   escaped_code, client_id, scope, escaped_redirect, escaped_cnf) < 0 ||
	    !body)
		goto done;
	ok = post_token(instance, body, token, error, sizeof(error));
	if (!ok)
		remember(session, error[0] ? error : "Could not get a desktop sign-in token.");
done:
	free(escaped_redirect);
	free(hint);
	free(url);
	free(callback);
	free(code);
	free(returned_state);
	free(escaped_code);
	free(escaped_cnf);
	free(body);
	if (!ok && session && !session->auth_detail[0])
		remember(session, "Could not get a desktop sign-in token.");
	return ok && token && *token;
}

static BOOL hydra_exchange_aad_token(freerdp* instance, HydraSession* session, const char* scope,
                                     const char* req_cnf, char** token)
{
	if (!session || !scope || !scope[0] || !req_cnf || !req_cnf[0])
	{
		remember(session, "Sign in again. The desktop needs a fresh Entra token.");
		return FALSE;
	}
	session->auth_detail[0] = '\0';
	if (hydra_silent_aad_token(instance, session, scope, req_cnf, token))
		return TRUE;
	if (token && *token)
	{
		free(*token);
		*token = NULL;
	}
	session->auth_detail[0] = '\0';
	return hydra_interactive_aad_token(instance, session, scope, req_cnf, token);
}

static BOOL hydra_get_access_token(freerdp* instance, AccessTokenType tokenType, char** token,
                                   size_t count, ...)
{
	HydraSession* session = session_from(instance);
	va_list arguments;
	if (!session || !token)
		return FALSE;
	*token = NULL;
	if (tokenType == ACCESS_TOKEN_TYPE_AAD)
	{
		const char* scope = NULL;
		const char* req_cnf = NULL;
		if (count < 2)
			return FALSE;
		va_start(arguments, count);
		scope = va_arg(arguments, const char*);
		req_cnf = va_arg(arguments, const char*);
		va_end(arguments);
		return hydra_exchange_aad_token(instance, session, scope, req_cnf, token);
	}
	if (!session->access_token || !session->access_token[0])
		return FALSE;
	*token = _strdup(session->access_token);
	return *token != NULL;
}

static BOOL hydra_gateway_message(freerdp* instance, UINT32 type, BOOL isDisplayMandatory,
                                  BOOL isConsentMandatory, size_t length, const WCHAR* message)
{
	(void)instance;
	(void)type;
	(void)isDisplayMandatory;
	(void)isConsentMandatory;
	(void)length;
	(void)message;
	return TRUE;
}

static SSIZE_T hydra_retry_dialog(freerdp* instance, const char* what, size_t current, void* userarg)
{
	HydraSession* session = session_from(instance);
	char message[192];
	const char* label = "Reconnecting";
	if (what && strcmp(what, "arm-transport") == 0)
		label = "Waiting for the cloud PC to start";
	snprintf(message, sizeof(message), "%s (attempt %zu)", label, current + 1);
	if (session)
		report(session, 0, message);
	return client_common_retry_dialog(instance, what, current, userarg);
}

static int hydra_logon_error(freerdp* instance, UINT32 data, UINT32 type)
{
	HydraSession* session = session_from(instance);
	if (session)
	{
		char message[128];
		snprintf(message, sizeof(message), "Logon notice (type %u)", type);
		report(session, 0, message);
	}
	(void)data;
	return 1;
}

static BOOL hydra_client_new(freerdp* instance, rdpContext* context)
{
	HydraContext* hydra = (HydraContext*)context;
	hydra->session = g_creating;
	if (g_creating)
		g_creating->instance = instance;
	instance->PreConnect = hydra_pre_connect;
	instance->PostConnect = hydra_post_connect;
	instance->PostDisconnect = hydra_post_disconnect;
	instance->AuthenticateEx = hydra_authenticate;
	instance->VerifyCertificateEx = hydra_verify_certificate;
	instance->VerifyChangedCertificateEx = hydra_verify_changed;
	instance->GetAccessToken = hydra_get_access_token;
	instance->PresentGatewayMessage = hydra_gateway_message;
	instance->LogonErrorInfo = hydra_logon_error;
	instance->RetryDialog = hydra_retry_dialog;
	return TRUE;
}

static void hydra_client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}

static DWORD WINAPI hydra_thread(LPVOID argument)
{
	HydraSession* session = (HydraSession*)argument;
	freerdp* instance = session->instance;
	DWORD count = 0;
	DWORD status = 0;
	HANDLE handles[64] = { 0 };
	char message[320];
	BOOL connected = FALSE;
	if (session->connect_error)
	{
		report(session, 0, session->connect_error);
		return 1;
	}
	connected = freerdp_connect(instance);
	if (!connected)
	{
		UINT32 code = freerdp_get_last_error(instance->context);
		const char* text = freerdp_get_last_error_string(code);
		if (session->auth_detail[0])
			snprintf(message, sizeof(message), "%s", session->auth_detail);
		else if (session->needs_credentials)
			snprintf(message, sizeof(message),
			         "This PC requires a user name and password before it will connect.");
		else
			snprintf(message, sizeof(message), "Connection failed (%s)",
			         text ? text : "unknown error");
		report(session, 0, message);
		return 1;
	}
	while (!freerdp_shall_disconnect_context(instance->context))
	{
		count = freerdp_get_event_handles(instance->context, handles, 64);
		if (count == 0)
			break;
		status = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
		if (status == WAIT_FAILED)
			break;
		if (!freerdp_check_event_handles(instance->context))
		{
			UINT32 code = freerdp_get_last_error(instance->context);
			const char* text = freerdp_get_last_error_string(code);
			if (code != FREERDP_ERROR_SUCCESS && text && text[0])
			{
				snprintf(message, sizeof(message), "Disconnected (%s)", text);
				freerdp_disconnect(instance);
				report(session, 0, message);
				notify_ended(session);
				return 0;
			}
			break;
		}
	}
	freerdp_disconnect(instance);
	report(session, 0, "Disconnected");
	notify_ended(session);
	return 0;
}

static char* copy_string(const char* value)
{
	if (!value)
		return NULL;
	return _strdup(value);
}

HydraSession* hydra_session_create(int argc, char** argv, const char* rdp_text, const char* password,
                                    const char* gateway_password, const char* access_token,
                                    const char* refresh_token, const char* extra_channels, int width,
                                    int height, const HydraCallbacks* callbacks, void* user)
{
	HydraSession* session = (HydraSession*)calloc(1, sizeof(HydraSession));
	RDP_CLIENT_ENTRY_POINTS entry;
	rdpSettings* settings = NULL;
	char** owned = NULL;
	int index = 0;
	if (!session)
		return NULL;
	pthread_mutex_init(&session->lock, NULL);
	if (callbacks)
		session->callbacks = *callbacks;
	session->user = user;
	session->password = copy_string(password);
	session->gateway_password = copy_string(gateway_password);
	session->access_token = copy_string(access_token);
	session->refresh_token = copy_string(refresh_token);
	session->width = width > 0 ? width : 1280;
	session->height = height > 0 ? height : 720;
	session->scale_percent = 100;
	hydra_channels_set_extra(extra_channels);

	ZeroMemory(&entry, sizeof(entry));
	entry.Size = sizeof(entry);
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.ContextSize = sizeof(HydraContext);
	entry.ClientNew = hydra_client_new;
	entry.ClientFree = hydra_client_free;
	g_creating = session;
	session->context = freerdp_client_context_new(&entry);
	g_creating = NULL;
	if (!session->context || !session->instance)
	{
		hydra_session_destroy(session);
		return NULL;
	}
	settings = session->context->settings;
	if (rdp_text && rdp_text[0])
	{
		freerdp_client_settings_parse_connection_file_buffer(settings, (const BYTE*)rdp_text,
		                                                     strlen(rdp_text));
	}
	if (argc > 0 && argv)
	{
		owned = (char**)calloc((size_t)argc + 1, sizeof(char*));
		if (!owned)
			session->connect_error = copy_string("Could not read the connection settings");
		else
		{
			int parsed = 0;
			for (index = 0; index < argc; index++)
				owned[index] = argv[index] ? _strdup(argv[index]) : _strdup("");
			parsed = freerdp_client_settings_parse_command_line(settings, argc, owned, TRUE);
			if (parsed < 0)
				session->connect_error = copy_string("Could not read the connection settings");
			for (index = 0; index < argc; index++)
				free(owned[index]);
			free(owned);
		}
	}
	if (session->password && session->password[0])
		freerdp_settings_set_string(settings, FreeRDP_Password, session->password);
	if (session->gateway_password && session->gateway_password[0])
		freerdp_settings_set_string(settings, FreeRDP_GatewayPassword, session->gateway_password);
	if (session->access_token && session->access_token[0])
		freerdp_settings_set_string(settings, FreeRDP_GatewayAccessToken, session->access_token);
	freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (UINT32)session->width);
	freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (UINT32)session->height);
	return session;
}

void hydra_session_start(HydraSession* session)
{
	if (!session || session->thread)
		return;
	session->running = 1;
	session->thread = CreateThread(NULL, 0, hydra_thread, session, 0, NULL);
	if (!session->thread)
		report(session, 0, "Could not start the session thread");
}

void hydra_session_stop(HydraSession* session)
{
	if (!session)
		return;
	if (session->context)
		freerdp_abort_connect_context(session->context);
	if (session->thread)
	{
		WaitForSingleObject(session->thread, INFINITE);
		CloseHandle(session->thread);
		session->thread = NULL;
	}
	if (session->resize_timer && session->context)
	{
		freerdp_timer_remove(session->context, (FreeRDP_TimerID)session->resize_timer);
		session->resize_timer = 0;
	}
	session->running = 0;
}

void hydra_session_destroy(HydraSession* session)
{
	if (!session)
		return;
	hydra_session_stop(session);
	if (session->context)
	{
		freerdp_client_context_free(session->context);
		session->context = NULL;
		session->instance = NULL;
	}
	free(session->password);
	free(session->gateway_password);
	free(session->access_token);
	free(session->refresh_token);
	free(session->clipboard_utf8);
	free(session->connect_error);
	pthread_mutex_destroy(&session->lock);
	free(session);
}

static rdpInput* session_input(HydraSession* session)
{
	if (!session || !session->instance || !session->instance->context)
		return NULL;
	return session->instance->context->input;
}

void hydra_session_key(HydraSession* session, int apple_keycode, int down, unsigned int unicode)
{
	rdpInput* input = session_input(session);
	DWORD vk = 0;
	DWORD scan = 0;
	if (!input)
		return;
	pthread_mutex_lock(&session->lock);
	vk = GetVirtualKeyCodeFromKeycode((DWORD)apple_keycode, WINPR_KEYCODE_TYPE_APPLE);
	scan = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
	if (scan != 0)
		freerdp_input_send_keyboard_event_ex(input, down ? TRUE : FALSE, FALSE, scan);
	else if (unicode > 0 && unicode <= 0xFFFF)
		freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE, (UINT16)unicode);
	pthread_mutex_unlock(&session->lock);
}

void hydra_session_mouse(HydraSession* session, int x, int y, int button, int down)
{
	rdpInput* input = session_input(session);
	UINT16 flags = PTR_FLAGS_MOVE;
	if (!input)
		return;
	if (button == 1)
		flags = PTR_FLAGS_BUTTON1 | (down ? PTR_FLAGS_DOWN : 0);
	else if (button == 2)
		flags = PTR_FLAGS_BUTTON2 | (down ? PTR_FLAGS_DOWN : 0);
	else if (button == 3)
		flags = PTR_FLAGS_BUTTON3 | (down ? PTR_FLAGS_DOWN : 0);
	if (x < 0)
		x = 0;
	if (y < 0)
		y = 0;
	pthread_mutex_lock(&session->lock);
	freerdp_input_send_mouse_event(input, flags, (UINT16)x, (UINT16)y);
	pthread_mutex_unlock(&session->lock);
}

void hydra_session_wheel(HydraSession* session, int x, int y, int delta)
{
	rdpInput* input = session_input(session);
	UINT16 flags = PTR_FLAGS_WHEEL;
	int amount = delta;
	if (!input || delta == 0)
		return;
	if (amount < 0)
	{
		flags |= PTR_FLAGS_WHEEL_NEGATIVE;
		amount = -amount;
	}
	if (amount > 0xFF)
		amount = 0xFF;
	flags |= (UINT16)amount;
	pthread_mutex_lock(&session->lock);
	freerdp_input_send_mouse_event(input, flags, (UINT16)(x < 0 ? 0 : x), (UINT16)(y < 0 ? 0 : y));
	pthread_mutex_unlock(&session->lock);
}

void hydra_session_resize(HydraSession* session, int width, int height, int scale_percent)
{
	if (!session)
		return;
	hydra_clamp_desktop(&width, &height);
	if (scale_percent < 100)
		scale_percent = 100;
	pthread_mutex_lock(&session->lock);
	session->width = width;
	session->height = height;
	session->scale_percent = scale_percent;
	if (width == session->sent_width && height == session->sent_height &&
	    scale_percent == session->sent_scale)
		session->pending_resize = 0;
	else
	{
		session->pending_resize = 1;
		hydra_schedule_resize_locked(session);
	}
	pthread_mutex_unlock(&session->lock);
}

int hydra_session_channel_write(HydraSession* session, const uint8_t* data, int length)
{
	UINT result = CHANNEL_RC_OK;
	if (!session || !data || length < 0)
		return -1;
	pthread_mutex_lock(&session->lock);
	if (!session->hydra_channel || !session->hydra_channel->Write)
		result = 1;
	else
		result = session->hydra_channel->Write(session->hydra_channel, (ULONG)length, data, NULL);
	pthread_mutex_unlock(&session->lock);
	return result == CHANNEL_RC_OK ? 0 : -1;
}

void hydra_session_channel_close(HydraSession* session)
{
	if (!session)
		return;
	pthread_mutex_lock(&session->lock);
	if (session->hydra_channel && session->hydra_channel->Close)
		session->hydra_channel->Close(session->hydra_channel);
	session->hydra_channel = NULL;
	pthread_mutex_unlock(&session->lock);
	if (session->callbacks.channel_closed)
		session->callbacks.channel_closed(session->user);
}
