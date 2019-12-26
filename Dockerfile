FROM centos:7

COPY lgtoclnt-19.2.0.1-1.x86_64.rpm \
     lgtoserv-19.2.0.1-1.x86_64.rpm \
     lgtonode-19.2.0.1-1.x86_64.rpm \
     lgtoxtdclnt-19.2.0.1-1.x86_64.rpm \
     lgtoauthc-19.2.0.1-1.x86_64.rpm /


# epel needed for the 'jq' package
# 'file' and 'net-tools' required by lgto but not listed as dep
RUN yum install -y epel-release && \
        yum install -y socat jq file java net-tools && \
        yum localinstall --nogpgcheck -y /lgtoclnt-19.2.0.1-1.x86_64.rpm \
        /lgtoserv-19.2.0.1-1.x86_64.rpm \
        /lgtonode-19.2.0.1-1.x86_64.rpm \
        /lgtoxtdclnt-19.2.0.1-1.x86_64.rpm \
        /lgtoauthc-19.2.0.1-1.x86_64.rpm && \
        yum clean all && rm -f /lgto*.rpm && \
        chmod 755 /opt/nsr/admin/networker.sh && \
        ln -s /opt/nsr/admin/networker.sh /etc/init.d/networker
# After installation in a Docker container, the file /etc/init.d/networker does
# not exist, but the nsrdr command needs it.

COPY authc_configure.resp /
RUN sed -i -r -e "s/_secret_/pW+$(date +%N)$RANDOM$$._k/" /authc_configure.resp && \
        /opt/nsr/authc-server/scripts/authc_configure.sh  -silent /authc_configure.resp && \
        sed -i -r -e 's/(TCUSER=).*/\1root/' /nsr/authc/bin/authcrc


COPY recover.sh /
COPY bootstrap.sh /
COPY mask_devices.nsradmin /

ENV RecoveryAreaGid 4
ENV RecoveryArea /recovery_area
ENV RecoverySocket "unix-listen:$RecoveryArea/networker.socket,reuseaddr,fork,mode=0600,unlink-early=1"

ENTRYPOINT [ "/bootstrap.sh" ]
