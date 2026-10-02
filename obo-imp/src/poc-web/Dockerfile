# Serves a prebuilt SPA (ng build --configuration production,azure); infra/azure/deploy.ps1 builds it first.
FROM nginxinc/nginx-unprivileged:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/poc-web/browser /usr/share/nginx/html
EXPOSE 8080
