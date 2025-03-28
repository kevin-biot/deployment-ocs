# Use Tomcat base image
FROM tomcat:9.0-jdk17

# Remove default webapps
RUN rm -rf /usr/local/tomcat/webapps/*

# Copy WAR to webapps directory
COPY target/java-webapp.war /usr/local/tomcat/webapps/ROOT.war

EXPOSE 8080
