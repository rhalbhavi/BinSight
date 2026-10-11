FROM eclipse-mosquitto:2

USER root
COPY mosquitto.conf /mosquitto/config/mosquitto.conf
COPY start-mosquitto.sh /usr/local/bin/start-mosquitto.sh
RUN chmod 755 /usr/local/bin/start-mosquitto.sh

USER mosquitto
ENTRYPOINT ["/usr/local/bin/start-mosquitto.sh"]