// Launch the packaged simulator without a shell or temporary startup files.
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <unistd.h>

#include "rules_cc/cc/runfiles/runfiles.h"

namespace {

bool SetEnvironment(const char* name, const std::string& value) {
  if (setenv(name, value.c_str(), 1) == 0) return true;
  std::cerr << "ngspice: cannot set " << name << ": " << std::strerror(errno)
            << '\n';
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 0) return 1;
  std::string error;
  std::unique_ptr<rules_cc::cc::runfiles::Runfiles> runfiles(
      rules_cc::cc::runfiles::Runfiles::Create(
          argv[0], BAZEL_CURRENT_REPOSITORY, &error));
  if (!runfiles) {
    std::cerr << "ngspice: " << error << '\n';
    return 1;
  }
  const std::string runtime = runfiles->Rlocation(
      std::string(BAZEL_CURRENT_REPOSITORY) + "/cli_runtime");
  char* resolved = realpath(runtime.c_str(), nullptr);
  if (!resolved) {
    std::cerr << "ngspice: cannot resolve runtime " << runtime << ": "
              << std::strerror(errno) << '\n';
    return 1;
  }
  const std::string install_dir(resolved);
  std::free(resolved);
  const char* input_dir = std::getenv("NGSPICE_INPUT_DIR");
  const bool has_input_dir = input_dir && *input_dir;
  if (!SetEnvironment("SPICE_SCRIPTS", install_dir + "/share/ngspice/launcher") ||
      !SetEnvironment("SPICE_LIB_DIR", install_dir + "/share/ngspice") ||
      !SetEnvironment("NGSPICE_CODE_MODEL_DIR", install_dir + "/lib/ngspice") ||
      !SetEnvironment("ngspice_bazel_has_input_dir", has_input_dir ? "1" : "0")) {
    return 1;
  }

  // Replace this process so the simulator retains its PID, terminal, signals,
  // arguments and exit status. The immutable startup file needs no cleanup.
  const std::string executable = install_dir + "/bin/ngspice";
  argv[0] = const_cast<char*>(executable.c_str());
  execv(executable.c_str(), argv);
  const int execution_error = errno;
  std::cerr << "ngspice: cannot execute " << executable << ": "
            << std::strerror(execution_error) << '\n';
  return execution_error == ENOENT ? 127 : 126;
}
