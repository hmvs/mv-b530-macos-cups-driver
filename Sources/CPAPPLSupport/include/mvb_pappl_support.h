/*
 * Non-variadic wrappers around PAPPL's logging calls.
 *
 * papplLog, papplLogJob and papplDeviceError are variadic, and Swift cannot
 * call C variadic functions. We only ever log a prepared string, so a fixed
 * "%s" wrapper is all that is needed.
 */
#ifndef MVB_PAPPL_SUPPORT_H
#define MVB_PAPPL_SUPPORT_H

#include <pappl/pappl.h>

void mvb_log(pappl_system_t *system, pappl_loglevel_t level, const char *message);
void mvb_log_job(pappl_job_t *job, pappl_loglevel_t level, const char *message);
void mvb_device_error(pappl_device_t *device, const char *message);

#endif /* MVB_PAPPL_SUPPORT_H */
