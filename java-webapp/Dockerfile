# Use Tomcat base image
FROM tomcat:9.0-jdk17

# Create the ROOT directory and fix permissions for non-root OpenShift container
RUN mkdir -p /usr/local/tomcat/webapps/ROOT && \
    chmod -R 777 /usr/local/tomcat/webapps

# Clean default apps just in case
RUN rm -rf /usr/local/tomcat/webapps/*

# Copy WAR file to Tomcat's ROOT
COPY target/java-webapp.war /usr/local/tomcat/webapps/ROOT.war

EXPOSE 8080
