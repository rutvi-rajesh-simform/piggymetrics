[![Build Status](https://travis-ci.org/sqshq/PiggyMetrics.svg?branch=master)](https://travis-ci.org/sqshq/PiggyMetrics)
[![codecov.io](https://codecov.io/github/sqshq/PiggyMetrics/coverage.svg?branch=master)](https://codecov.io/github/sqshq/PiggyMetrics?branch=master)
[![GitHub license](https://img.shields.io/github/license/mashape/apistatus.svg)](https://github.com/sqshq/PiggyMetrics/blob/master/LICENCE)
[![Join the chat at https://gitter.im/sqshq/PiggyMetrics](https://badges.gitter.im/sqshq/PiggyMetrics.svg)](https://gitter.im/sqshq/PiggyMetrics?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

# Piggy Metrics

Piggy Metrics is a simple financial advisor app built to demonstrate the [Microservice Architecture Pattern](http://martinfowler.com/microservices/) using Spring Boot, Spring Cloud and Docker. The project is intended as a tutorial, but you are welcome to fork it and turn it into something else!

<br>

![](https://cloud.githubusercontent.com/assets/6069066/13864234/442d6faa-ecb9-11e5-9929-34a9539acde0.png)
![Piggy Metrics](https://cloud.githubusercontent.com/assets/6069066/13830155/572e7552-ebe4-11e5-918f-637a49dff9a2.gif)

## Functional services

Piggy Metrics is decomposed into three core microservices. All of them are independently deployable applications organized around certain business domains.

<img width="880" alt="Functional services" src="https://cloud.githubusercontent.com/assets/6069066/13900465/730f2922-ee20-11e5-8df0-e7b51c668847.png">

#### Account service
Contains general input logic and validation: incomes/expenses items, savings and account settings.

Method	| Path	| Description	| User authenticated	| Available from UI
------------- | ------------------------- | ------------- |:-------------:|:----------------:|
GET	| /accounts/{account}	| Get specified account data	|  | 	
GET	| /accounts/current	| Get current account data	| × | ×
GET	| /accounts/demo	| Get demo account data (pre-filled incomes/expenses items, etc)	|   | 	×
PUT	| /accounts/current	| Save current account data	| × | ×
POST	| /accounts/	| Register new account	|   | ×


#### Statistics service
Performs calculations on major statistics parameters and captures time series for each account. Datapoint contains values normalized to base currency and time period. This data is used to track cash flow dynamics during the account lifetime.

Method	| Path	| Description	| User authenticated	| Available from UI
------------- | ------------------------- | ------------- |:-------------:|:----------------:|
GET	| /statistics/{account}	| Get specified account statistics	          |  | 	
GET	| /statistics/current	| Get current account statistics	| × | × 
GET	| /statistics/demo	| Get demo account statistics	|   | × 
PUT	| /statistics/{account}	| Create or update time series datapoint for specified account	|   | 


#### Notification service
Stores user contact information and notification settings (reminders, backup frequency etc). Scheduled worker collects required information from other services and sends e-mail messages to subscribed customers.

Method	| Path	| Description	| User authenticated	| Available from UI
------------- | ------------------------- | ------------- |:-------------:|:----------------:|
GET	| /notifications/settings/current	| Get current account notification settings	| × | ×	
PUT	| /notifications/settings/current	| Save current account notification settings	| × | ×

#### Notes
- Each microservice has its own database, so there is no way to bypass API and access persistence data directly.
- MongoDB is used as a primary database for each of the services.
- All services are talking to each other via the Rest API.

## Infrastructure
[Spring cloud](https://spring.io/projects/spring-cloud) provides powerful tools for developers to quickly implement common distributed systems patterns -
<img width="880" alt="Infrastructure services" src="https://cloud.githubusercontent.com/assets/6069066/13906840/365c0d94-eefa-11e5-90ad-9d74804ca412.png">

### Config service
[Spring Cloud Config](http://cloud.spring.io/spring-cloud-config/spring-cloud-config.html) is horizontally scalable centralized configuration service for distributed systems. It uses a pluggable repository layer that currently supports local storage, Git, and Subversion.

In this project, we are going to use `native profile`, which simply loads config files from the local classpath. You can see `shared` directory in [Config service resources](https://github.com/sqshq/PiggyMetrics/tree/master/config/src/main/resources). Now, when Notification-service requests its configuration, Config service responds with `shared/notification-service.yml` and `shared/application.yml` (which is shared between all client applications).

##### Client side usage
Just build Spring Boot application with `spring-cloud-starter-config` dependency, autoconfiguration will do the rest.

Now you don't need embedded properties in your application. Just provide `bootstrap.yml` with application name and Config service URL:
```yml
spring:
  application:
    name: notification-service
  cloud:
    config:
      uri: http://config:8888
      fail-fast: true
```

##### With Spring Cloud Config, you can change application config dynamically.
For example, [EmailService bean](https://github.com/sqshq/PiggyMetrics/blob/master/notification-service/src/main/java/com/piggymetrics/notification/service/EmailServiceImpl.java) is annotated with `@RefreshScope`. That means you can change e-mail text and subject without rebuild and restart the Notification service.

First, change required properties in Config server. Then make a refresh call to the Notification service:
`curl -H "Authorization: Bearer #token#" -XPOST http://127.0.0.1:8000/notifications/refresh`

You could also use Repository [webhooks to automate this process](http://cloud.spring.io/spring-cloud-config/spring-cloud-config.html#_push_notifications_and_spring_cloud_bus)

##### Notes
- `@RefreshScope` doesn't work with `@Configuration` classes and doesn't ignore `@Scheduled` methods.
- `fail-fast` property means that Spring Boot application will fail startup immediately if it cannot connect to Config Service.

### Auth service
Authorization responsibilities are extracted to a separate server, which grants [OAuth2 tokens](https://tools.ietf.org/html/rfc6749) for backend resource services. Auth Server is used for user authorization as well as for secure machine-to-machine communication inside the perimeter.

In this project, we use [`Password credentials`](https://tools.ietf.org/html/rfc6749#section-4.3) grant type for user authorization (since it's used only by the UI) and [`Client Credentials`](https://tools.ietf.org/html/rfc6749#section-4.4) grant for service-to-service communication.

Spring Cloud Security provides convenient annotations and autoconfiguration to make this easy to implement on both server and client side. You can learn more in [documentation](http://cloud.spring.io/spring-cloud-security/spring-cloud-security.html).

On the client side, everything works exactly the same as with traditional session-based authorization. You can retrieve `Principal` from the request, check user roles using expression-based access control and `@PreAuthorize` annotation.

Each PiggyMetrics client has a scope: `server` for backend services and `ui` for the browser. We can use `@PreAuthorize` annotation to protect controllers from external access:

```java
@PreAuthorize("#oauth2.hasScope('server')")
@RequestMapping(value = "accounts/{name}", method = RequestMethod.GET)
public List<DataPoint> getStatisticsByAccountName(@PathVariable String name) {
	return statisticsService.findByAccountName(name);
}
```

### API Gateway
Amazon API Gateway is the external edge for this system. It is the single public entry point used for request routing, auth integration, throttling, canary rollout, observability, and traffic policy.

In this mode, edge routing is managed by API Gateway route configuration (or OpenAPI import), not by an in-app Zuul proxy. Backend integrations should target stable DNS endpoints (for example internal ALB/NLB DNS names, service mesh DNS names, or private service DNS exposed through VPC networking).

#### Route model (path-based)
- `/accounts/*` -> `http://account-service.internal.example.local`
- `/statistics/*` -> `http://statistics-service.internal.example.local`
- `/notifications/*` -> `http://notification-service.internal.example.local`

#### Example OpenAPI integration snippet
```yml
paths:
  /notifications/{proxy+}:
    x-amazon-apigateway-any-method:
      parameters:
        - name: proxy
          in: path
          required: true
          schema:
            type: string
      x-amazon-apigateway-integration:
        type: http_proxy
        httpMethod: ANY
        connectionType: VPC_LINK
        uri: http://${stageVariables.notificationServiceDns}/notifications/{proxy}
```

This keeps edge behavior cloud-managed and makes service targets explicit via DNS, avoiding application-level edge dependencies.

### Service Discovery
Service Discovery allows automatic detection of network locations for registered services. These locations might have dynamically assigned addresses due to auto-scaling, failures, or upgrades.

The key part of service discovery is the registry. In this project, we use Netflix Eureka for internal service registration and health visibility.

With Spring Boot, you can build Eureka Registry using `spring-cloud-starter-eureka-server`, `@EnableEurekaServer`, and simple configuration properties.

Client support is enabled with `@EnableDiscoveryClient` and `bootstrap.yml` with application name:
```yml
spring:
  application:
    name: notification-service
```

This service will be registered with Eureka Server and provided with metadata such as host, port, health indicator URL, and home page. Eureka receives heartbeat messages from each instance belonging to the service. If heartbeat fails over a configurable timetable, the instance is removed from the registry.

Eureka also provides a simple interface where you can track running services and number of available instances: `http://localhost:8761`

### Load balancer, Circuit breaker and Http client

#### Ribbon
Ribbon is a client-side load balancer that gives control over HTTP and TCP client behavior. Compared to a traditional load balancer, there is no additional network hop because a client can contact the target service directly.

Out of the box, it integrates with Spring Cloud and service discovery. [Eureka Client](https://github.com/sqshq/PiggyMetrics#service-discovery) provides a dynamic list of available servers so Ribbon can balance between them.

#### Hystrix
Hystrix is an implementation of the [Circuit Breaker Pattern](http://martinfowler.com/bliki/CircuitBreaker.html), which gives control over latency and network failures while communicating with other services. The main idea is to stop cascading failures in distributed environments.

Hystrix also generates metrics on execution outcomes and latency for each command, which can be used to [monitor system behavior](https://github.com/sqshq/PiggyMetrics#monitor-dashboard).

#### Feign
Feign is a declarative Http client that integrates with Ribbon and Hystrix. A single `spring-cloud-starter-feign` dependency and `@EnableFeignClients` annotation gives a full set of tools including load balancing, circuit breaker, and Http client defaults.

Example from Account Service:

```java
@FeignClient(name = "statistics-service")
public interface StatisticsServiceClient {

	@RequestMapping(method = RequestMethod.PUT, value = "/statistics/{accountName}", consumes = MediaType.APPLICATION_JSON_UTF8_VALUE)
	void updateStatistics(@PathVariable("accountName") String accountName, Account account);

}
```

- Everything you need is just an interface.
- You can share `@RequestMapping` between Spring MVC controllers and Feign methods.
- The example specifies service id `statistics-service`, resolved by internal discovery.

### Monitor dashboard

In this project configuration, each microservice with Hystrix pushes metrics to Turbine via Spring Cloud Bus (with AMQP broker). The Monitoring project is a small Spring Boot application with [Turbine](https://github.com/Netflix/Turbine) and [Hystrix Dashboard](https://github.com/Netflix-Skunkworks/hystrix-dashboard).

Let's observe system behavior under load: Statistics Service imitates delay during request processing. Response timeout is set to 1 second:

<img width="880" src="https://cloud.githubusercontent.com/assets/6069066/14194375/d9a2dd80-f7be-11e5-8bcc-9a2fce753cfe.png">

<img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127349/21e90026-f628-11e5-83f1-60108cb33490.gif">	| <img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127348/21e6ed40-f628-11e5-9fa4-ed527bf35129.gif"> | <img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127346/21b9aaa6-f628-11e5-9bba-aaccab60fd69.gif"> | <img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127350/21eafe1c-f628-11e5-8ccd-a6b6873c046a.gif">
--- |--- |--- |--- |
| `0 ms delay` | `500 ms delay` | `800 ms delay` | `1100 ms delay`
| Well behaving system. Throughput is about 22 rps. Small number of active threads in Statistics service. Median service time is about 50 ms. | Number of active threads is growing. We can see thread-pool rejections and about 40% errors, but circuit is still closed. | Half-open state: ratio of failed commands is higher than 50%, so circuit breaker kicks in. After sleep window, next request goes through. | 100 percent of requests fail. Circuit is now permanently open. Retry after sleep time won't close circuit because a single request is too slow. |

### Log analysis

Centralized logging can be very useful while identifying problems in distributed environments. Elasticsearch, Logstash and Kibana stack lets you search and analyze logs, utilization and network activity data.

### Distributed tracing

Analyzing problems in distributed systems can be difficult, especially tracing requests that propagate from one microservice to another.

[Spring Cloud Sleuth](https://cloud.spring.io/spring-cloud-sleuth/) solves this by adding two IDs to logging: `traceId` and `spanId`. `spanId` represents a basic unit of work (for example sending an HTTP request). `traceId` contains a set of spans forming a tree-like structure.

The logs are as follows, notice `[appname,traceId,spanId,exportable]` entries from Slf4J MDC:

```text
2018-07-26 23:13:49.381  WARN [api-gateway,3216d0de1384bb4f,3216d0de1384bb4f,false] 2999 --- [nio-4000-exec-1] edge.request.router : Upstream timeout reached for account-service integration.
2018-07-26 23:13:49.562  INFO [account-service,3216d0de1384bb4f,404ff09c5cf91d2e,false] 3079 --- [nio-6000-exec-1] c.p.account.service.AccountServiceImpl   : new account has been created: test
```

- *`appname`*: Name of the application that logged the span from `spring.application.name`.
- *`traceId`*: ID assigned to a single request, job, or action.
- *`spanId`*: ID of a specific operation that took place.
- *`exportable`*: Whether the log should be exported to [Zipkin](https://zipkin.io/).

## Infrastructure automation

Deploying microservices with interdependence is more complex than deploying a monolithic application. It is important to have fully automated infrastructure. Continuous Delivery gives the following benefits:

- Ability to release software anytime.
- Any build could end up being a release.
- Build artifacts once, deploy as needed.

Here is a simple Continuous Delivery workflow implemented in this project:

<img width="880" src="https://cloud.githubusercontent.com/assets/6069066/14159789/0dd7a7ce-f6e9-11e5-9fbb-a7fe0f4431e3.png">

In this [configuration](https://github.com/sqshq/PiggyMetrics/blob/master/.travis.yml), Travis CI builds tagged images for each successful git push. So there are always `latest` images for each microservice on [Docker Hub](https://hub.docker.com/r/sqshq/) and older images tagged with git commit hash. It's easy to deploy any of them and quickly roll back if needed.

## Let's try it out

Note that starting 8 Spring Boot applications, 4 MongoDB instances and RabbitMQ requires at least 4Gb of RAM.

#### Before you start
- Install Docker and Docker Compose.
- Change environment variable values in `.env` file for more security or leave it as-is.
- Build the project: `mvn package [-DskipTests]`

#### Production mode
In this mode, all latest images are pulled from Docker Hub.
Just copy `docker-compose.yml` and run `docker-compose up`.

#### Development mode
If you'd like to build images yourself, clone the repository and build artifacts using Maven. After that, run `docker-compose -f docker-compose.yml -f docker-compose.dev.yml up`.

`docker-compose.dev.yml` inherits `docker-compose.yml` with additional possibility to build images locally and expose all container ports for convenient development.

If you'd like to start applications in Intellij Idea, either use [EnvFile plugin](https://plugins.jetbrains.com/plugin/7861-envfile) or manually export environment variables listed in `.env` file (make sure they were exported: `printenv`).

#### Important endpoints
- API Gateway invoke URL (example): `https://{api-id}.execute-api.{region}.amazonaws.com/{stage}`
- http://localhost:8761 - Eureka Dashboard
- http://localhost:9000/hystrix - Hystrix Dashboard (Turbine stream link: `http://turbine-stream-service:8080/turbine/turbine.stream`)
- http://localhost:15672 - RabbitMq management (default login/password: guest/guest)

## Contributions are welcome!

PiggyMetrics is open source and would greatly appreciate your help. Feel free to suggest and implement improvements.