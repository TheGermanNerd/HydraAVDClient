#include "hydra_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>
#include <winpr/error.h>

#include <freerdp/channels/cliprdr.h>
#include <winpr/user.h>

static char* utf16_to_utf8(const BYTE* data, size_t size)
{
	CFStringRef string = NULL;
	char* utf8 = NULL;
	CFIndex length = 0;
	CFIndex used = 0;
	if (!data || size < 2)
		return NULL;
	if (size >= 2 && data[size - 1] == 0 && data[size - 2] == 0)
		size -= 2;
	string = CFStringCreateWithBytes(NULL, data, (CFIndex)size, kCFStringEncodingUTF16LE, false);
	if (!string)
		return NULL;
	CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)), kCFStringEncodingUTF8, 0, false,
	                 NULL, 0, &used);
	utf8 = (char*)calloc((size_t)used + 1, 1);
	if (utf8)
	{
		CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)), kCFStringEncodingUTF8, 0,
		                 false, (UInt8*)utf8, used, &length);
	}
	CFRelease(string);
	return utf8;
}

static BYTE* utf8_to_utf16(const char* text, UINT32* size)
{
	CFStringRef string = NULL;
	CFIndex used = 0;
	BYTE* bytes = NULL;
	if (!text)
		return NULL;
	string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
	if (!string)
		return NULL;
	CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)), kCFStringEncodingUTF16LE, 0,
	                 false, NULL, 0, &used);
	bytes = (BYTE*)calloc((size_t)used + 2, 1);
	if (bytes)
	{
		CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)), kCFStringEncodingUTF16LE, 0,
		                 false, bytes, used, &used);
		*size = (UINT32)used + 2;
	}
	CFRelease(string);
	return bytes;
}

static UINT send_capabilities(CliprdrClientContext* cliprdr)
{
	CLIPRDR_GENERAL_CAPABILITY_SET general;
	CLIPRDR_CAPABILITIES capabilities;
	ZeroMemory(&general, sizeof(general));
	ZeroMemory(&capabilities, sizeof(capabilities));
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = 12;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
	capabilities.cCapabilitiesSets = 1;
	capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
	if (!cliprdr->ClientCapabilities)
		return ERROR_INVALID_PARAMETER;
	return cliprdr->ClientCapabilities(cliprdr, &capabilities);
}

static UINT send_format_list(HydraSession* session)
{
	CLIPRDR_FORMAT format;
	CLIPRDR_FORMAT_LIST list;
	if (!session->cliprdr || !session->cliprdr->ClientFormatList)
		return CHANNEL_RC_OK;
	ZeroMemory(&format, sizeof(format));
	ZeroMemory(&list, sizeof(list));
	format.formatId = CF_UNICODETEXT;
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = session->clipboard_utf8 ? 1 : 0;
	list.formats = session->clipboard_utf8 ? &format : NULL;
	return session->cliprdr->ClientFormatList(session->cliprdr, &list);
}

static UINT monitor_ready(CliprdrClientContext* cliprdr, const CLIPRDR_MONITOR_READY* ready)
{
	HydraSession* session = cliprdr ? (HydraSession*)cliprdr->custom : NULL;
	(void)ready;
	if (!session)
		return ERROR_INVALID_PARAMETER;
	session->clipboard_ready = 1;
	send_capabilities(cliprdr);
	return send_format_list(session);
}

static UINT server_format_list(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST* list)
{
	UINT32 index = 0;
	CLIPRDR_FORMAT_DATA_REQUEST request;
	if (!cliprdr || !list || !cliprdr->ClientFormatDataRequest)
		return ERROR_INVALID_PARAMETER;
	for (index = 0; index < list->numFormats; index++)
	{
		if (list->formats[index].formatId != CF_UNICODETEXT)
			continue;
		ZeroMemory(&request, sizeof(request));
		request.common.msgType = CB_FORMAT_DATA_REQUEST;
		request.requestedFormatId = CF_UNICODETEXT;
		return cliprdr->ClientFormatDataRequest(cliprdr, &request);
	}
	return CHANNEL_RC_OK;
}

static UINT server_format_data_request(CliprdrClientContext* cliprdr,
                                       const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	HydraSession* session = cliprdr ? (HydraSession*)cliprdr->custom : NULL;
	CLIPRDR_FORMAT_DATA_RESPONSE response;
	UINT32 size = 0;
	BYTE* data = NULL;
	UINT result = CHANNEL_RC_OK;
	if (!cliprdr || !cliprdr->ClientFormatDataResponse || !request)
		return ERROR_INVALID_PARAMETER;
	ZeroMemory(&response, sizeof(response));
	response.common.msgType = CB_FORMAT_DATA_RESPONSE;
	if (!session || request->requestedFormatId != CF_UNICODETEXT || !session->clipboard_utf8)
	{
		response.common.msgFlags = CB_RESPONSE_FAIL;
		return cliprdr->ClientFormatDataResponse(cliprdr, &response);
	}
	data = utf8_to_utf16(session->clipboard_utf8, &size);
	if (!data)
	{
		response.common.msgFlags = CB_RESPONSE_FAIL;
		return cliprdr->ClientFormatDataResponse(cliprdr, &response);
	}
	response.common.msgFlags = CB_RESPONSE_OK;
	response.common.dataLen = size;
	response.requestedFormatData = data;
	result = cliprdr->ClientFormatDataResponse(cliprdr, &response);
	free(data);
	return result;
}

static UINT server_format_data_response(CliprdrClientContext* cliprdr,
                                        const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	HydraSession* session = cliprdr ? (HydraSession*)cliprdr->custom : NULL;
	char* text = NULL;
	if (!session || !response)
		return ERROR_INVALID_PARAMETER;
	if ((response->common.msgFlags & CB_RESPONSE_FAIL) || !response->requestedFormatData)
		return CHANNEL_RC_OK;
	text = utf16_to_utf8(response->requestedFormatData, response->common.dataLen);
	if (!text)
		return CHANNEL_RC_OK;
	pthread_mutex_lock(&session->lock);
	free(session->clipboard_utf8);
	session->clipboard_utf8 = text;
	pthread_mutex_unlock(&session->lock);
	if (session->callbacks.clipboard)
		session->callbacks.clipboard(session->user, text);
	return CHANNEL_RC_OK;
}

static UINT format_list_response(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
	(void)cliprdr;
	(void)response;
	return CHANNEL_RC_OK;
}

void hydra_clipboard_attach(HydraSession* session, CliprdrClientContext* cliprdr)
{
	if (!session || !cliprdr)
		return;
	session->cliprdr = cliprdr;
	cliprdr->custom = session;
	cliprdr->MonitorReady = monitor_ready;
	cliprdr->ServerFormatList = server_format_list;
	cliprdr->ServerFormatDataRequest = server_format_data_request;
	cliprdr->ServerFormatDataResponse = server_format_data_response;
	cliprdr->ServerFormatListResponse = format_list_response;
}

void hydra_clipboard_detach(HydraSession* session)
{
	if (!session)
		return;
	if (session->cliprdr)
		session->cliprdr->custom = NULL;
	session->cliprdr = NULL;
	session->clipboard_ready = 0;
}

void hydra_session_set_clipboard(HydraSession* session, const char* utf8)
{
	if (!session)
		return;
	pthread_mutex_lock(&session->lock);
	free(session->clipboard_utf8);
	session->clipboard_utf8 = utf8 ? _strdup(utf8) : NULL;
	pthread_mutex_unlock(&session->lock);
	if (session->clipboard_ready)
		send_format_list(session);
}
