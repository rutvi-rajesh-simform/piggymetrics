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
GET	| /accounts/demo	| Get demo account data (pre-filled incomes/expenses items, etc)	|   |	×
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
- All services are talking to each other via the Rest API

## Infrastructure
[Spring cloud](https://spring.io/projects/spring-cloud) provides powerful tools for developers to quickly implement common distributed systems patterns.

<img width="880" alt="Infrastructure services" src="https://cloud.githubusercontent.com/assets/6069066/13906840/365c0d94-eefa-11e5-90ad-9d74804ca412.png">

### Dependency migration (messaging, discovery, config)

This project now uses AWS-native messaging/discovery/config integration for event flow and service registration.

#### Removed dependencies
- `spring-cloud-starter-bus-amqp`
- `spring-cloud-starter-netflix-eureka-client`
- `spring-cloud-starter-netflix-eureka-server`

#### Added dependencies
```xml
<dependency>
  <groupId>io.awspring.cloud</groupId>
  <artifactId>spring-cloud-aws-starter-sqs</artifactId>
</dependency>
<dependency>
  <groupId>io.awspring.cloud</groupId>
  <artifactId>spring-cloud-aws-starter-sns</artifactId>
</dependency>
<dependency>
  <groupId>io.awspring.cloud</groupId>
  <artifactId>spring-cloud-aws-starter-parameter-store-config</artifactId>
</dependency>
<dependency>
  <groupId>software.amazon.awssdk</groupId>
  <artifactId>servicediscovery</artifactId>
</dependency>
```

### Config service
[Spring Cloud Config](http://cloud.spring.io/spring-cloud-config/spring-cloud-config.html) can still be used for centralized configuration where needed, but runtime configuration distribution is now aligned with AWS config sources.

In this setup, services can resolve configuration from AWS Systems Manager Parameter Store (via Spring Cloud AWS config support) while keeping local profiles for development.

##### Client side usage
Build Spring Boot applications with:
- `spring-cloud-starter-config` (if Config Server is still used)
- `spring-cloud-aws-starter-parameter-store-config` for AWS-backed configuration

Example bootstrap configuration:
```yml
spring:
  application:
    name: notification-service
  config:
    import: aws-parameterstore:/config/notification-service/
```

##### Notes
- Keep `fail-fast` behavior enabled for critical config sources.
- Prefer scoped paths in Parameter Store (for example `/config/<service-name>/`) to isolate service settings.

### Auth service
Authorization responsibilities are extracted to a separate server, which grants [OAuth2 tokens](https://tools.ietf.org/html/rfc6749) for the backend resource services. Auth Server is used for user authorization as well as for secure machine-to-machine communication inside the perimeter.

In this project, I use [`Password credentials`](https://tools.ietf.org/html/rfc6749#section-4.3) grant type for users authorization (since it's used only by the UI) and [`Client Credentials`](https://tools.ietf.org/html/rfc6749#section-4.4) grant for service-to-service communciation.

Spring Cloud Security provides convenient annotations and autoconfiguration to make this really easy to implement on both server and client side. You can learn more about that in [documentation](http://cloud.spring.io/spring-cloud-security/spring-cloud-security.html).

On the client side, everything works exactly the same as with traditional session-based authorization. You can retrieve `Principal` object from the request, check user roles using the expression-based access control and `@PreAuthorize` annotation.

Each PiggyMetrics client has a scope: `server` for backend services and `ui` - for the browser. We can use `@PreAuthorize` annotation to protect controllers from  an external access:

``` java
@PreAuthorize("#oauth2.hasScope('server')")
@RequestMapping(value = "accounts/{name}", method = RequestMethod.GET)
public List<DataPoint> getStatisticsByAccountName(@PathVariable String name) {
	return statisticsService.findByAccountName(name);
}
```

### API Gateway
Amazon API Gateway is the single entry point into the system, used to handle requests and route them to the appropriate backend service or by [aggregating results from a scatter-gather call](http://techblog.netflix.com/2013/01/optimizing-netflix-api.html). It can also be used for authentication, insights, stress and canary testing, service migration, static response handling and active traffic management.

In this project, gateway behavior is implemented with Amazon API Gateway resources, methods, integrations, and stages. A simple route for the Notification service can be configured as follows:

```text
Resource: /notifications/{proxy+}
Method: ANY
Integration: HTTP endpoint for notification-service
Stage: prod
```

That means all requests starting with `/notifications` will be routed to the Notification service through API Gateway integration.

### Service Discovery

Service Discovery allows automatic detection of the network locations for all registered services. These locations might have dynamically assigned addresses due to auto-scaling, failures or upgrades.

The registry implementation in this project is now AWS Cloud Map (instead of Eureka). Services register their instance metadata in Cloud Map, and clients resolve healthy endpoints through Cloud Map APIs or integrated service discovery clients.

Client support includes startup registration and periodic health updates. During deployment/scale events, Cloud Map namespace records are updated automatically.

Example application properties:
```yml
aws:
  cloudmap:
    namespace: piggymetrics.local
    service:
      name: notification-service
```

### Load balancer, Circuit breaker and Http client

#### Ribbon
Ribbon is a client side load balancer which gives you a lot of control over the behaviour of HTTP and TCP clients. Compared to a traditional load balancer, there is no need in additional network hop - you can contact desired service directly.

Out of the box, it integrates with service discovery metadata and can balance requests across healthy instances.

#### Hystrix
Hystrix is the implementation of [Circuit Breaker Pattern](http://martinfowler.com/bliki/CircuitBreaker.html), which gives us a control over latency and network failures while communicating with other services. The main idea is to stop cascading failures in the distributed environment - that helps to fail fast and recover as soon as possible - important aspects of a fault-tolerant system that can self-heal.

Moreover, Hystrix generates metrics on execution outcomes and latency for each command, that we can use to [monitor system's behavior](https://github.com/sqshq/PiggyMetrics#monitor-dashboard).

#### Feign
Feign is a declarative Http client which seamlessly integrates with load balancing and circuit breaking. A single `spring-cloud-starter-openfeign` dependency and `@EnableFeignClients` annotation gives us a full set of tools, including load balancing, circuit breaker support and Http client with reasonable default configuration.

Here is an example from the Account Service:

``` java
@FeignClient(name = "statistics-service")
public interface StatisticsServiceClient {

	@RequestMapping(method = RequestMethod.PUT, value = "/statistics/{accountName}", consumes = MediaType.APPLICATION_JSON_UTF8_VALUE)
	void updateStatistics(@PathVariable("accountName") String accountName, Account account);

}
```

- Everything you need is just an interface
- You can share `@RequestMapping` part between Spring MVC controller and Feign methods
- Above example specifies just a desired service id

### Monitor dashboard

In this project configuration, each microservice publishes event and telemetry signals using AWS messaging primitives:
- SNS topics for fan-out event publication
- SQS queues for durable asynchronous consumption

The monitoring project remains a Spring Boot application with Turbine and Hystrix Dashboard for circuit/latency visualization, while event transport is no longer based on AMQP bus.

Let's observe the behavior of our system under load: Statistics Service imitates a delay during the request processing. The response timeout is set to 1 second:

<img width="880" src="https://cloud.githubusercontent.com/assets/6069066/14194375/d9a2dd80-f7be-11e5-8bcc-9a2fce753cfe.png">

<img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127349/21e90026-f628-11e5-83f1-60108cb33490.gif">	| <img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127348/21e6ed40-f628-11e5-9fa4-ed527bf35129.gif"> | <img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127346/21b9aaa6-f628-11e5-9bba-aaccab60fd69.gif"> | <img width="212" src="https://cloud.githubusercontent.com/assets/6069066/14127350/21eafe1c-f628-11e5-8ccd-a6b6873c046a.gif">
--- |--- |--- |--- |
| `0 ms delay` | `500 ms delay` | `800 ms delay` | `1100 ms delay`
| Well behaving system. Throughput is about 22 rps. Small number of active threads in the Statistics service. Median service time is about 50 ms. | The number of active threads is growing. We can see purple number of thread-pool rejections and therefore about 40% of errors, but the circuit is still closed. | Half-open state: the ratio of failed commands is higher than 50%, so the circuit breaker kicks in. After sleep window amount of time, the next request goes through. | 100 percent of the requests fail. The circuit is now permanently open. Retry after sleep time won't close the circuit again because a single request is too slow.

### Log analysis

Centralized logging can be very useful while attempting to identify problems in a distributed environment. Elasticsearch, Logstash and Kibana stack lets you search and analyze your logs, utilization and network activity data with ease.

### Distributed tracing

Analyzing problems in distributed systems can be difficult, especially trying to trace requests that propagate from one microservice to another.

[Spring Cloud Sleuth](https://cloud.spring.io/spring-cloud-sleuth/) solves this problem by providing support for the distributed tracing. It adds two types of IDs to the logging: `traceId` and `spanId`. `spanId` represents a basic unit of work, for example sending an HTTP request. The traceId contains a set of spans forming a tree-like structure. For example, with a distributed big-data store, a trace might be formed by a PUT request. Using `traceId` and `spanId` for each operation we know when and where our application is as it processes a request, making reading logs much easier.

The logs are as follows, notice the `[appname,traceId,spanId,exportable]` entries from the Slf4J MDC:

```text
2018-07-26 23:13:49.381  WARN [gateway,3216d0de1384bb4f,3216d0de1384bb4f,false] 2999 --- [nio-4000-exec-1] o.s.c.n.z.f.r.s.AbstractRibbonCommand    : The Hystrix timeout of 20000ms for the command account-service is set lower than the combination of the Ribbon read and connect timeout, 80000ms.
2018-07-26 23:13:49.562  INFO [account-service,3216d0de1384bb4f,404ff09c5cf91d2e,false] 3079 --- [nio-6000-exec-1] c.p.account.service.AccountServiceImpl   : new account has been created: test
```

- *`appname`*: The name of the application that logged the span from the property `spring.application.name`
- *`traceId`*: This is an ID that is assigned to a single request, job, or action
- *`spanId`*: The ID of a specific operation that took place
- *`exportable`*: Whether the log should be exported to [Zipkin](https://zipkin.io/)

## Infrastructure automation

Deploying microservices, with their interdependence, is much more complex process than deploying a monolithic application. It is really important to have a fully automated infrastructure. We can achieve following benefits with Continuous Delivery approach:

- The ability to release software anytime
- Any build could end up being a release
- Build artifacts once - deploy as needed

Here is a simple Continuous Delivery workflow, implemented in this project:

<img width="880" src="https://cloud.githubusercontent.com/assets/6069066/14159789/0dd7a7ce-f6e9-11e5-9fbb-a7fe0f4431e3.png">

In this [configuration](https://github.com/sqshq/PiggyMetrics/blob/master/.travis.yml), Travis CI builds tagged images for each successful git push. So, there are always the `latest` images for each microservice on [Docker Hub](https://hub.docker.com/r/sqshq/) and older images, tagged with git commit hash. It's easy to deploy any of them and quickly rollback, if needed.

## Let's try it out

Note that starting 8 Spring Boot applications and 4 MongoDB instances requires at least 4Gb of RAM.

#### Before you start
- Install Docker and Docker Compose.
- Change environment variable values in `.env` file for more security or leave it as it is.
- Build the project: `mvn package [-DskipTests]`

#### Production mode
In this mode, all latest images will be pulled from Docker Hub.
Just copy `docker-compose.yml` and hit `docker-compose up`

#### Development mode
If you'd like to build images yourself, you have to clone the repository and build artifacts using maven. After that, run `docker-compose -f docker-compose.yml -f docker-compose.dev.yml up`

`docker-compose.dev.yml` inherits `docker-compose.yml` with additional possibility to build images locally and expose all containers ports for convenient development.

If you'd like to start applications in Intellij Idea you need to either use [EnvFile plugin](https://plugins.jetbrains.com/plugin/7861-envfile) or manually export environment variables listed in `.env` file (make sure they were exported: `printenv`)

#### Important endpoints
- http://localhost:80 - Gateway
- http://localhost:9000/hystrix - Hystrix Dashboard
- AWS Console (Cloud Map) - Service registry namespace and instances
- AWS Console (SNS/SQS) - Event topics, subscriptions, and queues

## Contributions are welcome!

PiggyMetrics is open source, and would greatly appreciate your help. Feel free to suggest and implement any improvements.