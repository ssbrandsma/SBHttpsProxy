#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <curl/curl.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define VERSION "0.2.0"
#define MAX_REQUEST 16384
#define MAX_HEADERS 32768
#define MAX_WORKERS 8
#define WORKER_STACK (256U * 1024U)

typedef struct { int fd; } worker_arg;
typedef struct { int fd, started, status; char headers[MAX_HEADERS + 1]; size_t length, bytes; } transfer_ctx;
static pthread_mutex_t worker_lock = PTHREAD_MUTEX_INITIALIZER;
static int active_workers;
static const char *ca_bundle;

static void log_line(const char *format, ...) { va_list a; va_start(a,format); fputs("[sbproxy] ",stderr); vfprintf(stderr,format,a); fputc('\n',stderr); va_end(a); }
static int send_all(int fd,const void *data,size_t length) { const unsigned char *p=data; while(length){ssize_t n=send(fd,p,length,MSG_NOSIGNAL);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;p+=n;length-=(size_t)n;}return 0; }
static void send_error(int fd,int code,const char *reason) { char b[256];int n=snprintf(b,sizeof b,"HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",code,reason);if(n>0)(void)send_all(fd,b,(size_t)n); }
static int static_hop(const char *n) { return !strcasecmp(n,"connection")||!strcasecmp(n,"keep-alive")||!strcasecmp(n,"proxy-authenticate")||!strcasecmp(n,"proxy-authorization")||!strcasecmp(n,"te")||!strcasecmp(n,"trailer")||!strcasecmp(n,"transfer-encoding")||!strcasecmp(n,"upgrade"); }
static int get_name(const char *line,char *name,size_t capacity) { const char *c=strchr(line,':');size_t n;if(!c||c==line)return 0;n=(size_t)(c-line);if(n>=capacity)return 0;memcpy(name,line,n);name[n]=0;return 1; }
static int token_contains(const char *tokens,const char *name) { size_t nl=strlen(name);while(*tokens){const char *e;while(*tokens==' '||*tokens=='\t'||*tokens==',')tokens++;e=tokens;while(*e&&*e!=','&&*e!='\r'&&*e!='\n')e++;while(e>tokens&&(e[-1]==' '||e[-1]=='\t'))e--;if((size_t)(e-tokens)==nl&&!strncasecmp(tokens,name,nl))return 1;tokens=*e?e+1:e;}return 0; }
static const char *connection_tokens(const char *headers) { const char *line=headers;while(line&&*line){const char *next=strstr(line,"\r\n");if(!strncasecmp(line,"Connection:",11))return line+11;if(!next)break;line=next+2;}return ""; }
static const char *reason_phrase(int status) { switch(status){case 200:return "OK";case 206:return "Partial Content";case 304:return "Not Modified";case 400:return "Bad Request";case 404:return "Not Found";case 416:return "Range Not Satisfiable";default:return "Upstream Response";} }

static int emit_headers(transfer_ctx *ctx) {
    char status[96];const char *tokens=connection_tokens(ctx->headers),*line=ctx->headers;int n=snprintf(status,sizeof status,"HTTP/1.1 %d %s\r\n",ctx->status,reason_phrase(ctx->status));
    if(n<=0||send_all(ctx->fd,status,(size_t)n))return -1;
    while(line&&*line){const char *next=strstr(line,"\r\n");size_t len=next?(size_t)(next-line):strlen(line);char copy[4096],name[128];if(len>=sizeof copy)return -1;memcpy(copy,line,len);copy[len]=0;if(get_name(copy,name,sizeof name)&&!static_hop(name)&&!token_contains(tokens,name)){if(send_all(ctx->fd,copy,len)||send_all(ctx->fd,"\r\n",2))return -1;}if(!next)break;line=next+2;}
    if(send_all(ctx->fd,"Connection: close\r\n\r\n",21))return -1;
    ctx->started=1;
    return 0;
}
static size_t header_cb(char *data,size_t size,size_t count,void *opaque) {
    transfer_ctx *ctx=opaque;size_t len=size*count;
    if(len>=5&&!strncasecmp(data,"HTTP/",5)){const char *space=memchr(data,' ',len);ctx->status=space?atoi(space+1):0;ctx->length=0;ctx->headers[0]=0;return len;}
    if((len==2&&data[0]=='\r'&&data[1]=='\n')||(len==1&&data[0]=='\n')){if((ctx->status>=100&&ctx->status<200)||(ctx->status>=300&&ctx->status<400))return len;return emit_headers(ctx)?0:len;}
    if(ctx->length+len>MAX_HEADERS)return 0;
    memcpy(ctx->headers+ctx->length,data,len);ctx->length+=len;ctx->headers[ctx->length]=0;return len;
}
static size_t body_cb(char *data,size_t size,size_t count,void *opaque) { transfer_ctx *ctx=opaque;size_t len=size*count;if(!ctx->started)return ctx->status>=300&&ctx->status<400?len:0;if(send_all(ctx->fd,data,len))return 0;ctx->bytes+=len;return len; }
static int receive_request(int fd,char *request,size_t capacity,size_t *length_out) { size_t len=0;request[0]=0;while(len<capacity-1){ssize_t n=recv(fd,request+len,capacity-1-len,0);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;len+=(size_t)n;request[len]=0;if(strstr(request,"\r\n\r\n")){*length_out=len;return 0;}}return 1; }
static struct curl_slist *request_headers(char *headers) {
    struct curl_slist *result=NULL;char *save=NULL,*line;const char *tokens=connection_tokens(headers);(void)strtok_r(headers,"\r\n",&save);
    while((line=strtok_r(NULL,"\r\n",&save))){char name[128];if(get_name(line,name,sizeof name)&&strcasecmp(name,"host")&&!static_hop(name)&&!token_contains(tokens,name)){struct curl_slist *next=curl_slist_append(result,line);if(!next){curl_slist_free_all(result);return NULL;}result=next;}}
    return result;
}
static int health(int fd,int head) { const curl_version_info_data *i=curl_version_info(CURLVERSION_NOW);char body[256],headers[256];int bl=snprintf(body,sizeof body,"sbproxy %s\nlibcurl: %s\nTLS: %s\nstatus: OK\n",VERSION,i&&i->version?i->version:"unknown",i&&i->ssl_version?i->ssl_version:"unknown");int hl=snprintf(headers,sizeof headers,"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",head?0:bl);return send_all(fd,headers,(size_t)hl)||(!head&&send_all(fd,body,(size_t)bl)); }
static void release_worker(void) { pthread_mutex_lock(&worker_lock);active_workers--;pthread_mutex_unlock(&worker_lock); }

static void *worker_main(void *opaque) {
    worker_arg *arg=opaque;int fd=arg->fd;char request[MAX_REQUEST+1],copy[MAX_REQUEST+1],method[8],target[MAX_REQUEST+1],protocol[16],url[MAX_REQUEST+16];size_t request_len=0;CURL *curl=NULL;struct curl_slist *headers=NULL;transfer_ctx transfer;CURLcode result;struct timespec start,end;free(arg);
    int received=receive_request(fd,request,sizeof request,&request_len);if(received>0){send_error(fd,431,"Request Header Fields Too Large");goto done;}if(received<0||!strstr(request,"\r\n\r\n")||sscanf(request,"%7s %16384s %15s",method,target,protocol)!=3){send_error(fd,400,"Bad Request");goto done;}
    if(strcasecmp(method,"GET")&&strcasecmp(method,"HEAD")){send_error(fd,405,"Method Not Allowed");goto done;}if(!strcmp(target,"/health")){(void)health(fd,!strcasecmp(method,"HEAD"));goto done;}if(strncmp(target,"/https/",7)){send_error(fd,404,"Not Found");goto done;}if(!target[7]||!strchr(target+7,'/')){send_error(fd,400,"Malformed Proxy URL");goto done;}if(snprintf(url,sizeof url,"https://%s",target+7)>=(int)sizeof url){send_error(fd,414,"URI Too Long");goto done;}
    memcpy(copy,request,request_len+1);headers=request_headers(copy);curl=curl_easy_init();if(!curl){send_error(fd,500,"Internal Server Error");goto done;}memset(&transfer,0,sizeof transfer);transfer.fd=fd;
    curl_easy_setopt(curl,CURLOPT_URL,url);curl_easy_setopt(curl,CURLOPT_HTTPHEADER,headers);curl_easy_setopt(curl,CURLOPT_HTTPGET,1L);curl_easy_setopt(curl,CURLOPT_NOBODY,!strcasecmp(method,"HEAD")?1L:0L);curl_easy_setopt(curl,CURLOPT_FOLLOWLOCATION,1L);curl_easy_setopt(curl,CURLOPT_MAXREDIRS,8L);curl_easy_setopt(curl,CURLOPT_CONNECTTIMEOUT,15L);curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);curl_easy_setopt(curl,CURLOPT_IPRESOLVE,CURL_IPRESOLVE_V4);curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,body_cb);curl_easy_setopt(curl,CURLOPT_WRITEDATA,&transfer);curl_easy_setopt(curl,CURLOPT_HEADERFUNCTION,header_cb);curl_easy_setopt(curl,CURLOPT_HEADERDATA,&transfer);curl_easy_setopt(curl,CURLOPT_SSL_VERIFYPEER,1L);curl_easy_setopt(curl,CURLOPT_SSL_VERIFYHOST,2L);if(ca_bundle)curl_easy_setopt(curl,CURLOPT_CAINFO,ca_bundle);
    clock_gettime(CLOCK_MONOTONIC,&start);{const char *query=strchr(target+7,'?');int shown=(int)(query?(size_t)(query-(target+7)):strlen(target+7));if(shown>512)shown=512;log_line("%s %.*s%s",method,shown,target+7,query?" [query redacted]":"");}result=curl_easy_perform(curl);clock_gettime(CLOCK_MONOTONIC,&end);if(result!=CURLE_OK&&!transfer.started&&result!=CURLE_WRITE_ERROR)send_error(fd,502,"Bad Gateway");log_line("result=%d status=%d bytes=%zu duration_ms=%ld",(int)result,transfer.status,transfer.bytes,(end.tv_sec-start.tv_sec)*1000L+(end.tv_nsec-start.tv_nsec)/1000000L);
done: if(curl)curl_easy_cleanup(curl);curl_slist_free_all(headers);close(fd);release_worker();return NULL;
}
static int parse_port(const char *address) { char *end;long port;if(strncmp(address,"127.0.0.1:",10))return -1;errno=0;port=strtol(address+10,&end,10);return errno||*end||port<1||port>65535?-1:(int)port; }

int main(int argc,char **argv) {
    const char *listen_address="127.0.0.1:8765";int listener,one=1,port,index;struct sockaddr_in address;pthread_attr_t attributes;
    for(index=1;index<argc;index++){if(!strcmp(argv[index],"--help")){puts("usage: sbproxy [--listen 127.0.0.1:8765] [--ca-bundle PATH]");return 0;}else if(!strcmp(argv[index],"--version")){puts("sbproxy " VERSION);return 0;}else if(!strcmp(argv[index],"--listen")&&index+1<argc)listen_address=argv[++index];else if(!strcmp(argv[index],"--ca-bundle")&&index+1<argc)ca_bundle=argv[++index];else{fprintf(stderr,"unknown or incomplete option: %s\n",argv[index]);return 2;}}
    port=parse_port(listen_address);if(port<0){fputs("sbproxy only accepts --listen 127.0.0.1:<port>\n",stderr);return 2;}signal(SIGPIPE,SIG_IGN);if(curl_global_init(CURL_GLOBAL_DEFAULT)!=CURLE_OK)return 1;listener=socket(AF_INET,SOCK_STREAM,0);if(listener<0){perror("socket");return 1;}(void)setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one);memset(&address,0,sizeof address);address.sin_family=AF_INET;address.sin_port=htons((uint16_t)port);inet_pton(AF_INET,"127.0.0.1",&address.sin_addr);if(bind(listener,(struct sockaddr*)&address,sizeof address)||listen(listener,MAX_WORKERS)){perror("bind/listen");close(listener);return 1;}
    pthread_attr_init(&attributes);pthread_attr_setstacksize(&attributes,WORKER_STACK);pthread_attr_setdetachstate(&attributes,PTHREAD_CREATE_DETACHED);log_line("version %s listening %s workers=%d",VERSION,listen_address,MAX_WORKERS);
    for(;;){worker_arg *arg;pthread_t thread;int fd=accept(listener,NULL,NULL);if(fd<0){if(errno==EINTR)continue;perror("accept");continue;}pthread_mutex_lock(&worker_lock);if(active_workers>=MAX_WORKERS){pthread_mutex_unlock(&worker_lock);send_error(fd,503,"Service Unavailable");close(fd);continue;}active_workers++;pthread_mutex_unlock(&worker_lock);arg=malloc(sizeof *arg);if(!arg){send_error(fd,500,"Internal Server Error");close(fd);release_worker();continue;}arg->fd=fd;if(pthread_create(&thread,&attributes,worker_main,arg)){free(arg);send_error(fd,500,"Internal Server Error");close(fd);release_worker();}}
}
