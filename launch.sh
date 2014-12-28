#!/bin/bash

# --------------------------------------------------------------------
# This script connects to the remote machine, gets the code from the
# remote repository, compiles the application code, sends the json file
# for the experiment and executes it. Notice that if you want to use
# SCHED_DEADLINE, you may need to disable the admission controller, by
# running
# echo -1 > /proc/sys/kernel/sched_rt_runtime_us
# on the remote machine, before running the script.
# --------------------------------------------------------------------

# Variable declarations
APP_binary="./bin/application"
RESULT_dir="./results"
REMOTE_ip=$1
REMOTE_port=$2
REMOTE_username=$3
REFERENCE_run=$4
REFERENCE_trace=$5
LISTENING_PORT="23958"
LISTENER_IP=$(ip addr | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
TRACE_CMD_COMMAND="trace-cmd"

# --------------------------------------------------------------------
NUM_args=$#
if [ "$#" -ne 5 ]; then
    echo "[LAUNCH] parameters needed:"
    echo "         #1: remote ip"
    echo "         #2: remote port"
    echo "         #3: remote username"
    echo "         #4: json configuration file (on local machine)"
    echo "         #5: experiment name"
    echo "  TRACE_CMD_COMMAND can be set as an environment variable"
    echo "  to replace the original trace-cmd: it should be set as the"
    echo "  location of the binary for trace-cmd on the remote machine"
    exit
fi
# ------------------------------------------------------------

# ------------------------------------------------------------
# Making sure that it is possible to execute rt-bench on the
# remote host, via eventually git pull and compilation of
# benchmark.
# ------------------------------------------------------------
printf "[LAUNCH] Checking rt-bench presence on remote host ..."
ssh -p ${REMOTE_port} ${REMOTE_username}@${REMOTE_ip} \
  'if [ ! -d "rt-bench" ]; then git clone https://github.com/martinamaggio/rt-bench.git &>/dev/null; fi'
printf " done\n"

printf "[LAUNCH] Checking rt-bench compilation on remote host ..."
ssh -p ${REMOTE_port} ${REMOTE_username}@${REMOTE_ip} \
  "cd rt-bench; if [ ! -f $APP_binary ]; then \
  make &> /dev/null; \
  fi"
printf " done\n"

# ------------------------------------------------------------
# Executing benchmark on local and remote machine with
# UDP socket listening. Setup of platform via sending json
# file from local to remote machine. Creation of result
# directories both on local and on remote machine. Starting
# the listener on local machine and executing the program on
# remote machine.
# ------------------------------------------------------------
printf "[LAUNCH] Sending json file ..."
scp -P ${REMOTE_port} ${REFERENCE_run} \
  ${REMOTE_username}@${REMOTE_ip}:~/rt-bench/input/${REFERENCE_trace}.json \
  &> /dev/null
printf " done\n"

printf "[LAUNCH] Creating results directories ..."
mkdir -p ${RESULT_dir}
mkdir -p ${RESULT_dir}/${REFERENCE_trace}
ssh -p ${REMOTE_port} ${REMOTE_username}@${REMOTE_ip} \
  "mkdir -p rt-bench/${RESULT_dir}"
ssh -p ${REMOTE_port} ${REMOTE_username}@${REMOTE_ip} \
  "mkdir -p rt-bench/${RESULT_dir}/${REFERENCE_trace}"
printf " done\n"

printf "[LAUNCH] Starting listener ..."
rm -f *.dat
trace-cmd listen -p ${LISTENING_PORT} &>/dev/null &
LISTENER_PID=$!
printf " done\n"

echo "[LAUNCH] Connecting to remote machine and executing ..."
  # -e 'sched_migrate*' # monitor migrations
  # -e 'sched_wakeup*' # monitor scheduling wakeups
  # -e sched_switch # monitoring switch 
ssh -t -p ${REMOTE_port} ${REMOTE_username}@${REMOTE_ip} \
  "cd rt-bench && \
  sudo $TRACE_CMD_COMMAND record -N ${LISTENER_IP}:${LISTENING_PORT} \
  -e 'sched_migrate*' \
	~/rt-bench/$APP_binary ~/rt-bench/input/${REFERENCE_trace}.json \
	&> ${RESULT_dir}/${REFERENCE_trace}/output_${REFERENCE_trace}.txt"
kill -2 $LISTENER_PID
wait $LISTENER_PID

printf "[LAUNCH] Extracting data for ${REFERENCE_run} ..."
FILENAME=`ls trace*.dat`
cp $FILENAME \
  ${RESULT_dir}/${REFERENCE_trace}/${REFERENCE_trace}.dat
$TRACE_CMD_COMMAND report $FILENAME > ${RESULT_dir}/${REFERENCE_trace}/${REFERENCE_trace}.txt
rm $FILENAME
#echo "# Time, Thread number, Job number, CPU" > $RESULT_dir/${REFERENCE_trace}/${REFERENCE_trace}.csv
grep 'begins loop' $RESULT_dir/${REFERENCE_trace}/${REFERENCE_trace}.txt | \
	awk 'BEGIN {OFS = ", ";} { gsub(":", "", $3); gsub("\\[", "",$6); gsub("\\]", "",$6); gsub("\\[", "",$2); gsub("\\]", "",$2); print $3,$6,$9,$2}' \
	  > $RESULT_dir/${REFERENCE_trace}/${REFERENCE_trace}.csv
cp ${REFERENCE_run} ${RESULT_dir}/${REFERENCE_trace}/${REFERENCE_trace}.json
printf ' done\n'

printf "[LAUNCH] Removing unnecessary files ..."
ssh -p ${REMOTE_port} ${REMOTE_username}@${REMOTE_ip} \
  "rm -f rt-bench/*.log"
printf " done\n"

ANALYSIS_DIR="../../analysis/" 
cd ${RESULT_dir}/${REFERENCE_trace}
cp ${ANALYSIS_DIR}/analysis.m .

GENERATED_OCTAVE_SCRIPT="${REFERENCE_trace}.m"

echo "% ----------------------------------------" > $GENERATED_OCTAVE_SCRIPT
echo "clear;" >> $GENERATED_OCTAVE_SCRIPT
echo "experiment_name     = '$REFERENCE_trace';" >> $GENERATED_OCTAVE_SCRIPT
echo "% ----------------------------------------" >> $GENERATED_OCTAVE_SCRIPT
echo "addpath('$ANALYSIS_DIR');" >> $GENERATED_OCTAVE_SCRIPT
echo "process(experiment_name);" >> $GENERATED_OCTAVE_SCRIPT
echo "analysis;" >> $GENERATED_OCTAVE_SCRIPT
#echo "uplowbound(experiment_name)" >> $GENERATED_OCTAVE_SCRIPT

octave -q --no-window-system $GENERATED_OCTAVE_SCRIPT

cd ../..
