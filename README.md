# docker-networker-rt

EMC networker server instance for automated Disaster Recovery Testing.
Run recovery tests with minimal need for resources and tooling.

- Bootstraps an EMC networker server, typically from a remote clone device.
- Facilitates automated recovery tests by providing a generic interface for recovery requests:
  - no client passwords or client certificates
  - a simple unix socket interface which abstracts away the recovery command syntax.

The container is built from a standard Centos base image, hence building and
running the container simulates a Bare Metal Restore scenario.

Given
- a backup device containing regular backups and one or more bootstrap backups, accessible from within a docker container.
- the corresponding device configuration file (used by nsradmin to import the device configuration)
- a bootstrap ID and volume name (standard networker bootstrap information)

running this container will:
- configure the device in networker
- recover a subset of the server resources needed for the recovery tests
- recover the client resources from the bootstrap
- restore the client indexes
- starts listening on a socket for recovery requests

After an initial run, the container can be stopped and started as needed, while
keeping the media database.

## Usage

### Start the networker server container

The device configuration file is mounted under /bootstrapdevice.
The volume where the results of the recovery requests will be stored is mounted under /recovery_area.
In the default setup, this volume will also contain the listening socket.
The hostname of the container must be the same as the hostname of the original networker server.
```bash
docker run -d --name backupserver.example.net -h backupserver.example.com -v /root/clone_device:/bootstrapdevice -v /workspace:/recovery_area networker 3044979299,DCG_001_DCO
```

### Recover a file on the host where the container is running

```bash
$ echo '{ "client": "client.example.net", "path": "/var/lib/postgresql/data/backup_label" }' \
  | socat -,ignoreeof /workspace/networker.socket
07/31 16:37:47: starting recovery client.example.net /var/lib/postgresql/data/backup_label
Recovering 1 file from /var/lib/postgresql/data/backup_label into /recovery_area/client.example.net
Requesting 1 file(s), this may take a while...
Recover start time: Mon Jul 31 16:37:52 2017
Received 1 file(s) from NSR server 'backupserver.example.net'
Recover completion time: Mon Jul 31 16:37:53 2017

$ ls -l /workspace/client.example.net/
total 4
-rw------- 1 107 110 210 Jul 30 23:00 backup_label

```

### Recover a file in a container that runs extra checks

Mounting /workspace/client.example.net and the socket in a container allows to recover and validate files from within the container.

```bash
docker run --name "client recovery test" -h client.example.net -v /workspace/client.example.net:/recovery_area -v /workspace/networker.socket:/recovery_socket postgresql:drtest

```

There are security implications. It is degined to run on a secured host.
