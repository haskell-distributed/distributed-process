#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>

int server(int pings) {
  struct addrinfo hints, *res;
  int error, server_socket;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family   = PF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags    = AI_PASSIVE;

  error = getaddrinfo(NULL, "8080", &hints, &res); 
  if(error) {
    printf("server error: %s\n", gai_strerror(error));
    return -1;
  }

  server_socket = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if(server_socket < 0) {
    printf("server error: could not create socket\n");
    return -1;
  }

  int yes = 1;
  if(setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int)) < 0) {
    printf("server error: could not set socket options\n");
    return -1;
  }

  if(bind(server_socket, res->ai_addr, res->ai_addrlen) < 0) {
    printf("server error: could not bind to socket\n");
    return -1;
  }

  listen(server_socket, 5);

  int client_socket;
  struct sockaddr_storage client_addr;
  socklen_t addr_size;
  client_socket = accept(server_socket, (struct sockaddr *)&client_addr, &addr_size); 

  for(int i = 0; i < pings; i++) {
    char buf[8];
    ssize_t read = recv(client_socket, &buf, 8, 0);
    // printf("server received '%s'\n", buf);
    send(client_socket, buf, 8, 0);
  }

  freeaddrinfo(res);
  return 0;
}

int client(int pings) {
  printf("starting client\n");
  
  struct addrinfo hints, *res;
  int error, client_socket;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family   = PF_INET;
  hints.ai_socktype = SOCK_STREAM;

  error = getaddrinfo("127.0.0.1", "8080", &hints, &res); 
  if(error) {
    printf("client error: %s\n", gai_strerror(error));
    return -1;
  }

  client_socket = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if(client_socket < 0) {
    printf("client error: could not create socket\n");
    return -1;
  }

  if(connect(client_socket, res->ai_addr, res->ai_addrlen) < 0) {
    printf("client error: could not connect: %s\n", strerror(errno));
    return -1;
  }

  for(int i = 0; i < pings; i++) {
    send(client_socket, "ping123", 8, 0);
    
    char buf[8];
    ssize_t read = recv(client_socket, &buf, 8, 0);
    // printf("client received '%s'\n", buf);
  }

  printf("pinged %d times\n", pings);

  freeaddrinfo(res);
  return 0;
}

int usage(int argc, char** argv) {
  printf("usage: %s (server | client) <number of pings>\n", argv[0]);
  return -1;
}

int main(int argc, char** argv) {
  if(argc != 3) {
    return usage(argc, argv);
  }

  int pings = 0;
  sscanf(argv[2], "%d", &pings);

  if(!strcmp(argv[1], "server")) {
    return server(pings);
  } else if(!strcmp(argv[1], "client")) {
    return client(pings);
  } else {
    return usage(argc, argv);
  }
}
