#!/bin/sh
# based on bosco_quickstart, first version 5/2/2013, by Marco Mambelli

LOCAL_DIR=$HOME/.bosco
BOSCO_DIR=$HOME/bosco # change to /software/bosco later

# Change to have a different log file
LOG_FILE=$LOCAL_DIR/connect_setup.log
# To have no log file use:
# LOG_FILE=/dev/null

CONFIG_FILE=$LOCAL_DIR/condor_config
LOCAL_CONFIG=$LOCAL_DIR/condor_config.local
factory_config=$LOCAL_DIR/config/condor_config.factory

fix_port () {
  # Checks if the port is available
  # If the port is already used it sweeps until a port is available
  which netstat &> /dev/null
  if [ $? -ne 0 ]; then
    echo "No netstat available, unable to verify if port $1 is free" >> $LOG_FILE
    return 1
  fi
  let start_port=$1
  let tmp_max=$start_port+2000
  let tmp_port=$start_port
  while [ $tmp_port -le $tmp_max ]; do
    netstat -tulpn 2> /dev/null | grep $tmp_port > /dev/null 2>&1
    [ $? -eq 1 ]  && break
    let tmp_port=$tmp_port+1
  done
  if [ $tmp_port -eq $start_port ]; then
      # Initial port is available
      echo "Port $tmp_port available." >> $LOG_FILE
  elif [ $tmp_port -le $tmp_max ]; then
	  # Found a free port in the range	 
          echo "Found available port $tmp_port." >> $LOG_FILE
  else 
      echo "No free port in range $start_port to $tmp_port" >> $LOG_FILE
      return 1
  fi
  old_port=$(grep SHARED_PORT_ARGS $factory_config | cut -d ' ' -f 4)
  if [ $old_port -eq $tmp_port ]; then
      echo "Still using $tmp_port." >> $LOG_FILE
  else
      echo "Port $old_port is busy. Replacing $old_port with $tmp_port. Before:" >> $LOG_FILE
      grep $old_port $factory_config >> $LOG_FILE
      sed "s;$old_port;$tmp_port;" < $factory_config > ${factory_config}.new
      mv ${factory_config}.new ${factory_config}
      echo "After replacement:" >> $LOG_FILE
      grep $tmp_port $factory_config >> $LOG_FILE
      return 0
  fi
  return 1
}

echo "Connect Setup is starting."
echo "More information can be found in $LOG_FILE"
echo

# Check to see if local Bosco directory and all subdirectories exist

[ -d $LOCAL_DIR ] || mkdir $LOCAL_DIR && echo "Local Bosco files can be found in $LOCAL_DIR" >> $LOG_FILE
[ -d $LOCAL_DIR/log ] || mkdir $LOCAL_DIR/log && touch $LOCAL_DIR/log/MasterLog
[ -d $LOCAL_DIR/spool ] || mkdir $LOCAL_DIR/spool
[ -d $LOCAL_DIR/execute ] || mkdir $LOCAL_DIR/execute
[ -d $LOCAL_DIR/config ] || mkdir $LOCAL_DIR/config

# Check if config files exist

[ -f $CONFIG_FILE ] || cat > $CONFIG_FILE  <<EOF
##  Where is the machine-specific local config file for each host?            
LOCAL_CONFIG_FILE = $LOCAL_DIR/condor_config.local
LOCAL_CONFIG_DIR = $LOCAL_DIR/config
## Use a host-based security policy. By default CONDOR_HOST and the local machine will be allowed
use SECURITY: HOST_BASED
EOF

HOST_NAME=$(hostname)
LOCK=$(whoami)
CONDOR_ID=$(id -u)

[ -f $LOCAL_CONFIG ] || cat > $LOCAL_CONFIG <<EOF
RELEASE_DIR = $BOSCO_DIR
LOCAL_DIR = $LOCAL_DIR
COLLECTOR_NAME = Personal Condor at $HOST_NAME
GANGLIAD_METRICS_CONFIG_DIR = $BOSCO_DIR/etc/condor/ganglia.d
LOCK = /tmp/condor-lock.$LOCK
IS_BOSCO = True
MAIL = /bin/mailx
DAEMON_LIST = COLLECTOR, MASTER, NEGOTIATOR, SCHEDD
PREEN_ARGS = -r
CONDOR_HOST = $HOST_NAME
CONDOR_IDS = $CONDOR_ID.$CONDOR_ID
CREATE_CORE_FILES = False
GRIDMANAGER_MAX_SUBMITTED_JOBS_PER_RESOURCE = 10
EOF

[ -f $factory_config ] || echo '#
# Things you have to edit
#

##  What machine is your central manager?
CONDOR_HOST = $(FULL_HOSTNAME)
COLLECTOR_HOST = $(CONDOR_HOST):11000?sock=collector

##  This macro is used to specify a short description of your pool. 
COLLECTOR_NAME      = $(CONDOR_HOST)

# What hosts can run jobs to this cluster.
FLOCK_FROM = 

# Jobs submitted here can run at.
FLOCK_TO = 

##############################################
# Things that are safe to leave
#

CAMPUSFACTORY = $(SBIN)/runfactory
CAMPUSFACTORY_ARGS = -c $(LIBEXEC)/campus_factory/etc/campus_factory.conf
CAMPUSFACTORY_ENVIRONMENT = "PYTHONPATH=$(LIBEXEC)/campus_factory/python-lib CAMPUSFACTORY_DIR=$(LIBEXEC)/campus_factory _campusfactory_GLIDEIN_DIRECTORY=$(LIBEXEC)/campus_factory/share/glidein_jobs"

# Enabled Shared Port
USE_SHARED_PORT = True
SHARED_PORT_ARGS = -p 11000     

# What daemons should I run?
DAEMON_LIST = COLLECTOR, SCHEDD, NEGOTIATOR, MASTER, SHARED_PORT, CAMPUSFACTORY

# Remove glidein jobs that get put on hold for over 24 hours.
SYSTEM_PERIODIC_REMOVE = (GlideinJob == TRUE && JobStatus == 5 && time() - EnteredCurrentStatus > 3600*24*1)

#
# Security definitions
#
SEC_ENABLE_MATCH_PASSWORD_AUTHENTICATION = TRUE

SEC_DEFAULT_ENCRYPTION = OPTIONAL
SEC_DEFAULT_INTEGRITY = REQUIRED
# To allow status read
SEC_READ_INTEGRITY = OPTIONAL

ALLOW_ADMINISTRATOR = $(FULL_HOSTNAME) $(IP_ADDRESS)

SEC_PASSWORD_FILE = $(LOCAL_DIR)/passwdfile

# Daemons have their own passwdfile, always owned by the daemon user
COLLECTOR.SEC_PASSWORD_FILE = $(LOCAL_DIR)/passwdfile.daemon
NEGOTIATOR.SEC_PASSWORD_FILE = $(LOCAL_DIR)/passwdfile.daemon
GRIDMANAGER.SEC_PASSWORD_FILE = $(LOCAL_DIR)/passwdfile.daemon

SEC_ADVERTISE_STARTD_AUTHENTICATION = REQUIRED
SEC_ADVERTISE_STARTD_INTEGRITY = REQUIRED
SEC_ADVERTISE_STARTD_AUTHENTICATION_METHODS = PASSWORD
SEC_CLIENT_AUTHENTICATION_METHODS = FS, PASSWORD

ALLOW_ADVERTISE_STARTD = condor_pool@*/*
ALLOW_DAEMON = $(ALLOW_DAEMON) condor_pool@*/* $(FULL_HOSTNAME) $(IP_ADDRESS)

SEC_DAEMON_AUTHENTICATION = REQUIRED
SEC_DAEMON_INTEGRITY = REQUIRED
SEC_DAEMON_AUTHENTICATION_METHODS = FS,PASSWORD
SEC_WRITE_AUTHENTICATION_METHODS = FS,PASSWORD' > $factory_config

# Stop Bosco if already started, check just in case 
# bosco_stop --force > /dev/null (check to see if needed)
started=$(ps ux | grep condor_master | wc -l)
if [ $started -eq 1 ]; then
    # set and check user-specific port 
    ID=`expr $(id -u) % 64511`
    PORT=`expr $ID + 1024`
    fix_port $PORT
    
    # Start Bosco
    echo "************** Starting Bosco: ***********"
    bosco_start 2>> $LOG_FILE 1>/dev/tty
else
    echo "Bosco already started."
fi

REMOTE_HOST="login.ci-connect.uchicago.edu" 
REMOTE_USER=""
REMOTE_TYPE="condor"

# Connect UChicago RCC Connect cluster
cluster_set=$(bosco_cluster -l | grep $REMOTE_HOST | wc -w)
if [ $cluster_set -eq 1 ]; then
    # cluster already added
    echo "UChicago RCC Connect cluster already added."
else 
    echo "************** Connecting UChicago RCC Connect cluster to BOSCO: ***********"
    echo "At any time hit [CTRL+C] to interrupt."
    echo 

    q_tmp=""
    read -p "Type your username on $REMOTE_HOST (default $USER) and press [ENTER]: " q_tmp </dev/tty
    if [ "x$q_tmp" = "x" ]; then 
	REMOTE_USER=$USER
    else
	REMOTE_USER=$q_tmp
    fi

    echo "Connecting $REMOTE_HOST, user: $REMOTE_USER, queue manager: $REMOTE_TYPE"
    bosco_cluster --add $REMOTE_USER@$REMOTE_HOST $REMOTE_TYPE 2>> $LOG_FILE

    if [ $? -ne 0 ]; then
	echo "Failed to connect the cluster $REMOTE_HOST. Please check your data and retry."
	exit 2
    fi

    echo "$REMOTE_HOST connected"
fi

echo "************** Testing the cluster (resource): ***********"
echo "This may take up to 2 minutes... please wait."
test=$(bosco_cluster --test $REMOTE_USER@$REMOTE_HOST 2>> $LOG_FILE)
echo "BOSCO on $REMOTE_HOST Tested"
if [ $? -ne 0 ]; then
  echo "Failed to test the cluster $REMOTE_HOST. Please check your data and retry."
  exit 3
fi

if [ "x$REMOTE_USER" = "x" ]; then
    REMOTE_USER="username"
fi

echo "************** Congratulations, Bosco is now setup to work with $REMOTE_HOST! ***********"
cat >/dev/tty <<EOF
You are ready to submit jobs with the "condor_submit" command.
Remember to setup the environment all the time you want to use Bosco:
module load connect

Here is a quickstart guide about BOSCO:
https://twiki.grid.iu.edu/bin/view/CampusGrids/BoscoQuickStart

To remove Bosco you can run:
module load connect; bosco_uninstall --all

Here is a submit file example (supposing you want to run "myjob.sh"):
universe = grid
grid_resource = batch condor $REMOTE_USER@$REMOTE_HOST
Executable = myjob.sh
arguments = 
output = myjob.output.txt
error = myjob.error.txt
log = myjob.log
transfer_output_files = 
should_transfer_files = YES
when_to_transfer_output = ON_EXIT
queue 1
EOF
