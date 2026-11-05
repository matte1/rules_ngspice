#!/usr/bin/env bash
# Exercise the exported CLI and its installed runtime assets as a consumer.
set -euo pipefail

if [[ $# != 3 || ! $2 =~ ^(true|false)$ || ! $3 =~ ^(true|false)$ ]]; then
  echo "Usage: $0 NGSPICE_EXECUTABLE EXPECT_XSPICE EXPECT_OPENMP" >&2
  exit 1
fi
case "$1" in
  /*) ngspice=$1 ;;
  *) ngspice="$PWD/$1" ;;
esac
case "$0" in
  /*) test_script=$0 ;;
  *) test_script="$PWD/$0" ;;
esac
expect_xspice=$2
expect_openmp=$3
if [[ -n ${TEST_SRCDIR:-} ]]; then
  data_dir="$TEST_SRCDIR/$TEST_WORKSPACE"
else
  data_dir=$(cd "$(dirname "$0")" && pwd)
fi
work_dir=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/ngspice-cli.XXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT
# A real file is required: an empty directory falls through to ~/.spiceinit.
# Keep system initialization enabled so the launcher loads its code models.
printf '%s\n' '* Controlled initialization for the BCR test' \
  'echo NGSPICE_USER_INITIALIZATION_OK' > "$work_dir/.spiceinit"
export SPICE_USERINIT_DIR="$work_dir" LC_ALL=C
export OMP_DYNAMIC=FALSE OMP_THREAD_LIMIT=2
cd "$work_dir"

# Explicit sourcing must find both installed support scripts and caller inputs.
# spectrum intentionally reports its usage when invoked without arguments.
# Upstream startup used a 512-byte buffer for the combined sourcepath and
# truncated the spinit path at 501 bytes. Exercise the sourcepath here and
# the immutable spinit path in the relocated-runtime test below, independently
# of Bazel's output-root length. Keep each component below NAME_MAX and each
# full filename below macOS's 1024-byte PATH_MAX.
long_path="$work_dir/Long Source Paths With MixedCase"
while [[ ${#long_path} -lt 560 ]]; do
  long_path="$long_path/Nested Directory With MixedCase And Spaces"
done
export NGSPICE_INPUT_DIR="$long_path/Input Directory With MixedCase"
if [[ ${#NGSPICE_INPUT_DIR} -ge 900 ]]; then
  echo 'Test temporary root leaves insufficient room for long-path regression' >&2
  exit 1
fi
mkdir -p "$NGSPICE_INPUT_DIR"
cat > "$NGSPICE_INPUT_DIR/input_probe" <<'EOF'
* Input directory lookup probe
.control
echo NGSPICE_INPUT_DIRECTORY_OK
.endc
.end
EOF
# Upstream searches beside the netlist before SPICE_USERINIT_DIR. Use our own
# directory to avoid picking up any unrelated .spiceinit, and exercise argv
# forwarding with a filename containing spaces.
script_circuit="$work_dir/Runtime Scripts With Spaces.cir"
cp "$data_dir/runtime_scripts.cir" "$script_circuit"
if ! PATH=/nonexistent "$ngspice" -b "$script_circuit" > scripts.log 2>&1; then
  cat scripts.log >&2
  exit 1
fi
# Check the printed path as well as the lookup, so lowercasing is detected even
# on a case-insensitive filesystem where the wrong-case directory still opens.
check_runtime_scripts() {
  local log=$1
  if ! grep -Fq 'usage: spectrum startfreq stop step vec' "$log" ||
     ! grep -Fxq 'NGSPICE_INPUT_DIRECTORY_OK' "$log" ||
     ! grep -Fq "$NGSPICE_INPUT_DIR" "$log"; then
    cat "$log" >&2
    echo 'Installed or caller-provided script lookup failed' >&2
    return 1
  fi
}
check_runtime_scripts scripts.log
if ! grep -Fxq 'NGSPICE_USER_INITIALIZATION_OK' scripts.log; then
  cat scripts.log >&2
  echo 'The controlled user initialization file was not loaded' >&2
  exit 1
fi

run_circuit() {
  local circuit=$1 log=$2
  shift 2
  if ! PATH=/nonexistent "$ngspice" "$@" -b "$circuit" > "$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  # Some ngspice command failures do not change its process exit status.
  if grep -Eiq '(^Error|^Fatal|^Warning:.*(model|library).*not found)' "$log"; then
    cat "$log" >&2
    return 1
  fi
}

if ! PATH=/nonexistent "$ngspice" -n -b "$script_circuit" > no-user-init.log 2>&1; then
  cat no-user-init.log >&2
  exit 1
fi
check_runtime_scripts no-user-init.log
if grep -Fq 'NGSPICE_USER_INITIALIZATION_OK' no-user-init.log; then
  cat no-user-init.log >&2
  echo 'The -n option did not skip user initialization' >&2
  exit 1
fi

# execv must preserve the simulator's status, including a deliberate nonzero
# status from the upstream quit command.
exit_circuit="$work_dir/Exit Status With Spaces.cir"
cat > "$exit_circuit" <<'EOF'
Launcher exit status forwarding
.control
quit 17
.endc
.end
EOF
exit_status=0
PATH=/nonexistent "$ngspice" -b "$exit_circuit" > exit-status.log 2>&1 || exit_status=$?
if [[ $exit_status != 17 ]]; then
  cat exit-status.log >&2
  echo "Expected simulator exit status 17, observed $exit_status" >&2
  exit 1
fi

check_numeric_data() {
  local file=$1 columns=$2
  # Reject NaN/Inf and malformed rows before AWK arithmetic can coerce them.
  awk -v columns="$columns" '
    NR == 1 { next }
    {
      if (NF != columns) bad = 1
      for (i = 1; i <= NF; i++) {
        if ($i !~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/)
          bad = 1
        if ($i + 0 > 1e100 || $i + 0 < -1e100) bad = 1
      }
    }
    END { exit (bad || NR < 2) }
  ' "$file" || { echo "Invalid numeric data in $file" >&2; return 1; }
}

run_circuit "$data_dir/voltage_divider.cir" divider.log
check_numeric_data divider.dat 2
# The immutable startup must not expand a missing input-directory variable.
# An explicitly empty value has the same meaning as an unset value.
(
  unset NGSPICE_INPUT_DIR
  run_circuit "$data_dir/voltage_divider.cir" input-unset.log
  export NGSPICE_INPUT_DIR=
  run_circuit "$data_dir/voltage_divider.cir" input-empty.log
)
for feature in xspice openmp; do
  if [[ $feature == xspice ]]; then
    pattern='XSPICE extensions included'
    expected=$expect_xspice
  else
    pattern='OpenMP multithreading for BSIM3, BSIM4 enabled'
    expected=$expect_openmp
  fi
  actual=false
  if grep -Fq "$pattern" divider.log; then actual=true; fi
  if [[ $actual != "$expected" ]]; then
    echo "Expected $feature=$expected, observed $actual" >&2
    cat divider.log >&2
    exit 1
  fi
done
awk '
  NR == 1 { next }
  NF != 2 || $2 < 4.999999 || $2 > 5.000001 { exit 1 }
  END { if (NR != 2) exit 1 }
' divider.dat || { cat divider.log >&2; echo 'Incorrect voltage divider result' >&2; exit 1; }

run_circuit "$data_dir/klu_rc.cir" klu.log
if ! grep -Fq 'Using KLU as Direct Linear Solver' klu.log; then
  cat klu.log >&2
  echo 'The RC regression did not select the KLU solver' >&2
  exit 1
fi
for file in klu-op.dat klu-real-again.dat; do
  check_numeric_data "$file" 3
  awk '
    function abs(x) { return x < 0 ? -x : x }
    NR == 1 { next }
    NF != 3 || abs($2 - 5) > 1e-8 || abs($3 + 0.005) > 1e-11 { bad = 1 }
    END { exit (bad || NR != 2) }
  ' "$file" || { cat klu.log >&2; echo "KLU real solve failed: $file" >&2; exit 1; }
done
check_numeric_data klu-ac.dat 5
awk '
  function abs(x) { return x < 0 ? -x : x }
  NR == 1 { next }
  {
    expected_frequency = 10 * exp(log(10) * (NR - 2) / 4)
    omega_rc = 2 * atan2(0, -1) * $1 * 0.001
    expected_real = 2 / (4 + omega_rc * omega_rc)
    expected_imag = -omega_rc / (4 + omega_rc * omega_rc)
    if (abs($1 - expected_frequency) > 1e-9 * expected_frequency ||
        abs($2 - expected_real) > 1e-9 || abs($3 - expected_imag) > 1e-9 ||
        abs($4 - (expected_real - 1) / 1000) > 1e-12 ||
        abs($5 - expected_imag / 1000) > 1e-12) bad = 1
  }
  END { exit (bad || NR != 18) }
' klu-ac.dat || {
  cat klu.log >&2
  echo 'KLU complex AC solve differs from the analytic RC transfer function' >&2
  exit 1
}

if [[ $expect_xspice == true ]]; then
  run_circuit "$data_dir/xspice_analog.cir" analog.log
  check_numeric_data analog.dat 3
  awk '
    function abs(x) { return x < 0 ? -x : x }
    NR == 1 { next }
    NF != 3 || abs($3 - 3 * $2) > 1e-7 { bad = 1 }
    $2 > 0.49 { high++ }
    $2 < 0.01 { low++ }
    END { exit (bad || NR < 50 || high < 10 || low < 10) }
  ' analog.dat || { cat analog.log >&2; echo 'XSPICE analog gain failed' >&2; exit 1; }

  # -n skips user initialization, but system startup must still load models.
  cp analog.dat analog-with-user-init.dat
  rm analog.dat
  run_circuit "$data_dir/xspice_analog.cir" analog-no-user-init.log -n
  if ! cmp -s analog-with-user-init.dat analog.dat; then
    cat analog-no-user-init.log >&2
    echo 'XSPICE analog results changed when user initialization was skipped' >&2
    exit 1
  fi

  run_circuit "$data_dir/xspice_digital.cir" digital.log
  check_numeric_data digital.dat 3
  awk '
    NR == 1 { next }
    # Check well inside each settled plateau, away from propagation delay.
    $1 > 7e-6 && $1 < 13e-6 {
      high++
      if (NF != 3 || $2 < 0.99 || $3 > 0.01 || $3 < -0.01) bad = 1
    }
    $1 > 17e-6 && $1 < 23e-6 {
      low++
      if (NF != 3 || $2 > 0.01 || $3 < 0.99 || $3 > 1.01) bad = 1
    }
    END { exit (bad || high < 10 || low < 10) }
  ' digital.dat || { cat digital.log >&2; echo 'XSPICE digital inverter failed' >&2; exit 1; }
fi

if [[ $expect_openmp == true ]]; then
  for threads in 1 2; do
    mkdir "$work_dir/threads$threads"
    cd "$work_dir/threads$threads"
    sed "s/@THREADS@/$threads/" "$data_dir/openmp_bsim.cir" > bsim.cir
    run_circuit bsim.cir bsim.log
    check_numeric_data bsim.dat 4
  done
  cd "$work_dir"
  awk '
    function abs(x) { return x < 0 ? -x : x }
    FNR == 1 { next }
    NR == FNR {
      count++
      if (NF != 4) bad = 1
      for (i = 1; i <= NF; i++) serial[FNR, i] = $i
      if ($2 < -0.001) conducting++
      if ($2 > -0.000001 && $2 <= 0) cutoff++
      next
    }
    {
      parallel_count++
      if (NF != 4) bad = 1
      for (i = 1; i <= NF; i++)
        if (abs($i - serial[FNR, i]) > 1e-10 + 1e-7 * abs(serial[FNR, i])) bad = 1
    }
    END { exit (bad || count < 30 || count != parallel_count || !conducting || !cutoff) }
  ' threads1/bsim.dat threads2/bsim.dat || {
    cat threads1/bsim.log threads2/bsim.log >&2
    echo 'BSIM3/BSIM4 serial and parallel sweeps differ or are degenerate' >&2
    exit 1
  }
fi

if [[ -n ${TEST_SRCDIR:-} && ${NGSPICE_BCR_MANIFEST_TEST:-0} == 0 ]]; then
  # Re-run the complete suite with only a manifest and a runtime path longer
  # than the former spinit limit, containing spaces and uppercase letters.
  # This exercises immutable startup, the launcher, and quoted model paths.
  # Sandboxed sh_test executions may have only the symlink tree, without its
  # MANIFEST file. Find the native runtime tree without a repository name.
  runtime_directories=()
  for candidate in "$TEST_SRCDIR"/*/cli_runtime; do
    if [[ -x "$candidate/bin/ngspice" ]]; then
      runtime_directories+=("$candidate")
    fi
  done
  if [[ ${#runtime_directories[@]} != 1 ]]; then
    echo 'Expected one ngspice CLI install tree in test runfiles' >&2
    exit 1
  fi
  runtime_directory=${runtime_directories[0]}
  runtime_key=${runtime_directory#"$TEST_SRCDIR/"}
  # Check optional co-simulation assets as well as the models loaded by the
  # simulator. Bazel may represent tree-artifact files as sandbox runfile links.
  runtime_assets=(
    share/ngspice/launcher/spinit
    share/ngspice/scripts/{spinit,setplot,spectrum}
  )
  if [[ $expect_xspice == true ]]; then
    runtime_assets+=(
      lib/ngspice/{spice2poly,analog,digital,xtradev,xtraevt,table,tlines}.cm
      lib/ngspice/{ivlng.so,ivlng.vpi}
      share/ngspice/scripts/{vlnggen,ghnggen}
      share/ngspice/scripts/src/{verilator_shim.cpp,verilator_main.cpp,ghdl_shim.h,ghdl_shim.c,ghdl_vpi.c}
      share/ngspice/scripts/src/ngspice/{cosim.h,miftypes.h,cmtypes.h,coroutine.h,coroutine_cosim.h,coroutine_shim.h}
    )
  else
    for model in spice2poly analog digital xtradev xtraevt table tlines ivlng; do
      for suffix in cm so vpi; do
        if [[ -e "$runtime_directory/lib/ngspice/$model.$suffix" ]]; then
          echo "XSPICE-disabled runtime unexpectedly contains $model.$suffix" >&2
          exit 1
        fi
      done
    done
  fi
  for asset in "${runtime_assets[@]}"; do
    if [[ ! -s "$runtime_directory/$asset" ]]; then
      echo "Missing runtime asset: $asset" >&2
      exit 1
    fi
  done
  for init_file in scripts/spinit launcher/spinit; do
    if grep -Eq '@[A-Za-z_][A-Za-z_0-9]*@|bazel-out/|/execroot/' \
        "$runtime_directory/share/ngspice/$init_file"; then
      echo "Installed $init_file contains unresolved placeholders or a build path" >&2
      exit 1
    fi
  done
  relocated_runtime="$long_path/Runtime With MixedCase And Spaces"
  if [[ ${#relocated_runtime} -ge 850 ]]; then
    echo 'Test temporary root leaves insufficient room for relocated runtime assets' >&2
    exit 1
  fi
  mkdir -p "$relocated_runtime"
  # Materialize sandbox runfile links so this copy can run independently of the
  # original tree. Make the copy writable for cleanup of read-only Bazel outputs.
  cp -RL "$runtime_directory/." "$relocated_runtime/"
  chmod -R u+w "$relocated_runtime"
  if [[ ! -x "$relocated_runtime/bin/ngspice" ]]; then
    echo 'The relocated ngspice executable is missing' >&2
    exit 1
  fi
  relocated_manifest="$work_dir/relocated_manifest"
  {
    printf '%s %s\n' "$runtime_key" "$relocated_runtime"
    if [[ -f "$TEST_SRCDIR/_repo_mapping" ]]; then
      printf '%s %s\n' _repo_mapping "$TEST_SRCDIR/_repo_mapping"
    fi
  } > "$relocated_manifest"
  (
    unset RUNFILES_DIR RUNFILES_REPO_MAPPING
    export RUNFILES_MANIFEST_FILE="$relocated_manifest"
    export NGSPICE_BCR_MANIFEST_TEST=1
    mkdir "$work_dir/temporary directory with spaces"
    export TMPDIR="$work_dir/temporary directory with spaces"
    bash "$test_script" "$ngspice" "$expect_xspice" "$expect_openmp"
  )
  echo 'ngspice manifest-only long runtime path with spaces passed'
fi

echo "ngspice CLI smoke passed (xspice=$expect_xspice, openmp=$expect_openmp)"
