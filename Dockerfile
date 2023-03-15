FROM debian:11.6
MAINTAINER Alexis Ducastel <alexis@ducastel.net>

RUN apt-get update && DEBIAN_FRONTEND=noninteractive && \
    apt-get install -y \
    easy-rsa \
    dnsutils \
    iptables \
    netmask \
    mawk \
    rsync \
    openssl \
    openvpn \
    wget \
    python3-pip \
    gcc python-dev libkrb5-dev \
    && apt-get clean

RUN apt-get install -y build-essential python3-dev \
    libldap2-dev libsasl2-dev

RUN pip3 install pykerberos
RUN pip3 install python-ldap
RUN pip3 install paramiko
RUN pip3 install requests

COPY bin/* /usr/local/bin/
RUN chmod 744 /usr/local/bin/entry.sh && \
    chown root:root /usr/local/bin/entry.sh && \
    chmod 744 /usr/local/bin/openvpn-* && \
    chown root:root /usr/local/bin/openvpn-*

RUN chmod +x /usr/local/bin/entry.sh

ENTRYPOINT ["/usr/local/bin/entry.sh"]
