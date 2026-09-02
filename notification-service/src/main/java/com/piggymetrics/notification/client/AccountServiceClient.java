package com.piggymetrics.notification.client;

import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;

@FeignClient(
	name = "account-service",
	url = "${services.account-service.url:}"
)
public interface AccountServiceClient {

	@RequestMapping(method = RequestMethod.GET, value = "/accounts/{accountName}", produces = MediaType.APPLICATION_JSON_VALUE)
	String getAccount(@PathVariable("accountName") String accountName);

}