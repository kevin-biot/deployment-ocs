# Use Tomcat base image
FROM tomcat:9.0-jdk17

# Create and fix permissions for both webapps and Catalina/localhost
RUN mkdir -p /usr/local/tomcat/webapps/ROOT \
    /usr/local/tomcat/conf/Catalina/localhost && \
    chmod -R 777 /usr/local/tomcat/webapps \
    && chmod -R 777 /usr/local/tomcat/conf/Catalina

# Clean default apps just in case (after creating dirs)
RUN rm -rf /usr/local/tomcat/webapps/*

# Copy WAR file to ROOT
COPY target/java-webapp.war /usr/local/tomcat/webapps/ROOT.war

EXPOSE 8080
