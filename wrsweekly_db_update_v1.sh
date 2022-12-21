#!/bin/bash

REGION="us-east-1"

# Important: valur below is only for testing purposes. Do not use hardcoded values unless strictly necessary
WEEKLY_DB_INSTANCE_ID="i-0bc004e29a4041311"
#WEEKLY_DB_VOLUME_ID="vol-0daabd678b90df2da"


check_status() {

    max_tries="$1"
    test_command="$2"
    jq_filter="$3"
    required_value="$4"
    error="$5"

    ok="false"
    for i in `seq 1 $max_tries`; do
        return_value=$(eval ${test_command} )
        return_value=$(echo $return_value | eval $jq_filter)
        echo $return_value
        echo $required_value
        if [ "$return_value" == "$required_value" ]; then
            ok="true"
            break
        else
            echo -n "."
        fi
        sleep 5
    done
    if [ "$ok" == "false" ]; then
        printf "\n\e[31mERROR:\e[0m $error\n"
        exit 1
    fi
}


start_weekly_ec2() {
    echo "Starting EC2 instance..."
    max_tries="10"
    aws_command="aws ec2 start-instances --instance-ids "$WEEKLY_DB_INSTANCE_ID" --region $REGION"
    jq_filter="jq -r '.StartingInstances[0].CurrentState.Name'"
    required_status="running"
    error_msg="Failed to start ec2 instance"
    success_msg="ec2 instance started successfully"
    check_status "$max_tries" "$aws_command" "$jq_filter" "$required_status" "$error_msg"
    [[ $? == "0" ]] && echo $success_msg
}

stop_weekly_ec2() {
    echo "Stopping EC2 instance..."
    max_tries="20"
    aws_command="aws ec2 stop-instances --instance-ids "$WEEKLY_DB_INSTANCE_ID" --region $REGION"
    jq_filter="jq -r '.StoppingInstances[0].CurrentState.Name'"
    required_status="stopped"
    error_msg="Failed to stop ec2 instance"
    success_msg="ec2 instance stopped successfully"
    check_status "$max_tries" "$aws_command" "$jq_filter" "$required_status" "$error_msg"
    [[ $? == "0" ]] && echo $success_msg
}

get_weekly_volume_id() {
    echo "Obtaining /srv volume id"
    max_tries="10"
    aws_command="aws ec2 describe-instances --region $REGION --instance-id "$WEEKLY_DB_INSTANCE_ID""
    jq_filter="jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[1].Ebs.VolumeId'| cut -c 1-3 | sed 's/vol/true/g'"
    required_status="true"
    error_msg="Failed to retrieve volume id"
    check_status "$max_tries" "$aws_command" "$jq_filter" "$required_status" "$error_msg"
    [[ $? == "0" ]] && echo "Instance volume_id obtained successfully" && \
    export WEEKLY_DB_VOLUME_ID=$(eval ${aws_command} | jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[1].Ebs.VolumeId') && \
    echo $WEEKLY_DB_VOLUME_ID
}

detach_weekly_volume_id() {
    echo "Detaching volume..."
    max_tries="10"
    aws_command="aws ec2 detach-volume --volume-id $WEEKLY_DB_VOLUME_ID --instance-id $WEEKLY_DB_INSTANCE_ID"
    jq_filter="jq -r '.State'"
    required_status="detaching"
    error_msg="Failed to detach volume $WEEKLY_DB_VOLUME_ID"
    volume_status_cmd="aws ec2 describe-volumes --volume-ids $WEEKLY_DB_VOLUME_ID"
    volume_status=$(eval ${volume_status_cmd} | jq -r '.Volumes[0].State')
    if [ "$volume_status" == "in-use" ]; then
        check_status "$max_tries" "$aws_command" "$jq_filter" "$required_status" "$error_msg"
        aws ec2 delete-volume --volume-id $WEEKLY_DB_VOLUME_ID
        [[ $? == "0" ]] && echo "Volume detached and deleted successfully" &&  echo $WEEKLY_DB_VOLUME_ID
    else
        echo "Deleting volume $WEEKLY_DB_VOLUME_ID which is in $volume_status status.."
        aws ec2 delete-volume --volume-id $WEEKLY_DB_VOLUME_ID
    fi
}

attach_weekly_volume_id() {
    echo "Attaching volume..."
    max_tries="15"
    aws_command="aws ec2 attach-volume --volume-id $WEEKLY_DB_VOLUME_ID --instance-id $WEEKLY_DB_INSTANCE_ID --device /dev/sdf"
    jq_filter="jq -r '.State'"
    required_status="attaching"
    error_msg="Failed to attach volume $WEEKLY_DB_VOLUME_ID"
    check_status "$max_tries" "$aws_command" "$jq_filter" "$required_status" "$error_msg"
    [[ $? == "0" ]] && echo "Volume attached successfully" &&  echo $WEEKLY_DB_VOLUME_ID
}

get_last_liveDB_snapshot_id(){
    WEEKAGODATE=$(date +%F -d '7 days ago')
    echo $WEEKAGODATE
    return_value=$(aws ec2 describe-snapshots --filters Name=tag:Name,Values=aws-sql1-weekly-backup --query "Snapshots[?(StartTime>='$WEEKAGODATE')]" | jq -r '.[0].SnapshotId')
    LAST_SNAPSHOT_LIVE_DB_ID=$(echo $return_value)
    [[ $? == "0" ]] && echo "Snapshot identified successfully" &&  echo $LAST_SNAPSHOT_LIVE_DB_ID
}

create_volume_from_from_snapshot() {
    echo "Creating volume from snapshot..."
    aws_command="aws ec2 create-volume --volume-type gp3 --iops 3000 --snapshot-id $LAST_SNAPSHOT_LIVE_DB_ID --availability-zone us-east-1a"
    jq_filter="jq -r '.VolumeId'"
    error_msg="Failed to create volume from snapshot $LAST_SNAPSHOT_LIVE_DB_ID"
    return_value=$(eval ${aws_command})
    WEEKLY_DB_VOLUME_ID=$(echo $return_value | eval $jq_filter)
    return_value=$(echo $WEEKLY_DB_VOLUME_ID | cut -c 1-3 | sed 's/vol/true/g')
    echo $return_value
    if [ "$return_value" == "true" ]; then
        echo $WEEKLY_DB_VOLUME_ID
    else
        printf "\n\e[31mERROR:\e[0m $error_msg\n"
        exit 1
    fi
    [[ $? == "0" ]] && echo "Volume created successfully" &&  echo $WEEKLY_DB_VOLUME_ID
}

identify_last_liveDB_snapshot(){
    aws ec2 describe-snapshots --filters Name=tag:Name,Values=aws-sql1-weekly-backup
}


####

echo "Stopping weekly db EC2 instance..."
stop_weekly_ec2

echo "Detaching weekly db volume..."
get_weekly_volume_id && stop_weekly_ec2 && detach_weekly_volume_id

echo "Retrieve last weekly snapshot of live db and use it to create new volume"
get_last_liveDB_snapshot_id && create_volume_from_from_snapshot && echo "Attach volume to weekly db" && attach_weekly_volume_id

echo "Starting weekly db EC2 instance..."
start_weekly_ec2
