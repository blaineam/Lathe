// The four Tor API calls Lathe uses, declared here rather than imported.
//
// The upstream xcframework ships headers but no module map, so Swift cannot
// import it as a module — and the headers it does ship are Tor's entire
// internal tree, which would drag every one of its private structs into the
// build if they were exposed wholesale.
//
// `tor_api.h` is the one deliberately public interface, and these are its
// declarations copied verbatim. The definitions come from the linked static
// library; this is a promise about their signatures, not an implementation.
#ifndef LATHE_CTOR_SHIM_H
#define LATHE_CTOR_SHIM_H

typedef struct tor_main_configuration_t tor_main_configuration_t;

/// Allocates a configuration for one Tor instance.
tor_main_configuration_t *tor_main_configuration_new(void);

/// Sets the command line. Tor keeps these pointers rather than copying the
/// strings, so the caller has to keep them alive for as long as Tor runs.
int tor_main_configuration_set_command_line(tor_main_configuration_t *cfg,
                                            int argc, char **argv);

void tor_main_configuration_free(tor_main_configuration_t *cfg);

/// Returns a socket already authenticated as the owning controller, or -1.
/// Must be called before tor_run_main. Lathe reads BOOTSTRAP progress from it
/// and uses it to put the client to sleep and wake it again.
int tor_main_configuration_setup_control_socket(tor_main_configuration_t *cfg);

/// The version of the linked daemon.
const char *tor_api_get_provider_version(void);

/// Runs Tor. Blocks until the daemon exits, so it needs a thread of its own.
int tor_run_main(const tor_main_configuration_t *cfg);

#endif
