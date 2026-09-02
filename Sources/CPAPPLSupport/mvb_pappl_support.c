#include "include/mvb_pappl_support.h"

void mvb_log(pappl_system_t *system, pappl_loglevel_t level, const char *message)
{
    papplLog(system, level, "%s", message);
}

void mvb_log_job(pappl_job_t *job, pappl_loglevel_t level, const char *message)
{
    papplLogJob(job, level, "%s", message);
}

void mvb_device_error(pappl_device_t *device, const char *message)
{
    papplDeviceError(device, "%s", message);
}
