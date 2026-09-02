package com.piggymetrics.account;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.openfeign.EnableFeignClients;
import org.springframework.security.config.annotation.method.configuration.EnableGlobalMethodSecurity;
import org.springframework.security.oauth2.config.annotation.web.configuration.EnableOAuth2Client;

/**
 * Account service bootstrap.
 *
 * Service-to-service endpoints should be supplied through externalized configuration
 * (environment/application properties) to support cloud-native service URL resolution.
 *
 * Shared dependency management for AWS SDK v2 and Spring Cloud AWS Secrets Manager
 * integration is handled in the build configuration layer.
 */
@SpringBootApplication
@EnableOAuth2Client
@EnableFeignClients
@EnableGlobalMethodSecurity(prePostEnabled = true)
public class AccountApplication {

	public static void main(String[] args) {
		SpringApplication.run(AccountApplication.class, args);
	}

}