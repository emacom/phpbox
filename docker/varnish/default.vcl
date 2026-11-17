vcl 4.1;

backend default {
    .host = "web";
    .port = "8080";
    .first_byte_timeout = 600s;
}
