package com.piggymetrics.notification.repository;

import com.piggymetrics.notification.domain.Recipient;
import org.springframework.data.mongodb.repository.Query;
import org.springframework.data.repository.CrudRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface RecipientRepository extends CrudRepository<Recipient, String> {

	Recipient findByAccountName(String name);

	@Query("{ $and: [ " +
			"{ 'scheduledNotifications.BACKUP.active': true }, " +
			"{ $expr: { $lt: [ " +
			"'$scheduledNotifications.BACKUP.lastNotified', " +
			"{ $subtract: [ '$$NOW', { $multiply: [ '$scheduledNotifications.BACKUP.frequency', 86400000 ] } ] } " +
			"] } } " +
			"] }")
	List<Recipient> findReadyForBackup();

	@Query("{ $and: [ " +
			"{ 'scheduledNotifications.REMIND.active': true }, " +
			"{ $expr: { $lt: [ " +
			"'$scheduledNotifications.REMIND.lastNotified', " +
			"{ $subtract: [ '$$NOW', { $multiply: [ '$scheduledNotifications.REMIND.frequency', 86400000 ] } ] } " +
			"] } } " +
			"] }")
	List<Recipient> findReadyForRemind();

}