# nginx/Dockerfile
FROM nginx:alpine

RUN rm -f /etc/nginx/conf.d/default.conf

COPY jenkins.conf /etc/nginx/conf.d/jenkins.conf
COPY zabbix.conf /etc/nginx/conf.d/zabbix.conf