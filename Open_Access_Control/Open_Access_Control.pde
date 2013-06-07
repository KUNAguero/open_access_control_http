/*
 * Open Source RFID Access Controller - HTTP
 *
 * 
 * Based on Open Source RFID Access Controller code by:
 * Arclight - arclight@23.org
 * Danozano - danozano@gmail.com
 * See: http://code.google.com/p/open-access-control/
 *
 * and
 * 
 * Zyphlar's open-access-control-minimal-http
 * See: https://github.com/zyphlar/open-access-control-minimal-http
 *
 * Notice: This is free software and is probably buggy. Use it at
 * at your own peril.  Use of this software may result in your
 * doors being left open, your stuff going missing, or buggery by
 * high seas pirates. No warranties are expressed on implied.
 * You are warned.
 *
 * This program interfaces the Arduino to RFID, PIN pad and all
 * other input devices using the Wiegand-26 Communications
 * Protocol. It is recommended that the keypad inputs be
 * opto-isolated in case a malicious user shorts out the 
 * input device.
 * Outputs go to relays for door hardware/etc control.
 *
 * Relay outputs on digital pins 6,7,8,9 //TODO: fix this conflict -WB
 * Reader 1: pins 2,3
 * Reader 2: pins 4,5
 * Ethernet: pins 10,11,12,13 (reserved for the Ethernet shield)
 *
 * This should all really be broken out into simple libraries to make
 * variants simpler to create.
 */

/////////////////
// Includes
/////////////////

#include <SPI.h>          
#include <Ethernet.h>
#include <SD.h>           // SD card library for config and tag cache

#include <WIEGAND26.h>    // Wiegand 26 reader format libary
#include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts

// Create an instance of the various C++ libraries we are using.
WIEGAND26 wiegand26;  // Wiegand26 (RFID reader serial protocol) library
PCATTACH pcattach;    // Software interrupt library

/////////////////
// Global variables
/////////////////

byte reader1Pins[]={2,3};               // Reader 1 pins
byte reader2Pins[]={4,5};               // Reader 2 pins
byte RELAYPIN1 = 7;
byte RELAYPIN2 = 8;

// Need to eventually get this from SD config

#define RELAYDELAY 2000                 // How long to open door lock once access is granted. (1000 = 1sec)

char http1[] = "GET /auth/doors/";
char http2[] = " HTTP/1.0";

// Enter a MAC address and IP address for your controller below.
// The IP address will be dependent on your local network:
byte mac[] = {  0x90, 0xA2, 0xDA, 0x0D, 0x87, 0xA8 };
IPAddress ip(10,100,0,99);
IPAddress server(10,100,200,100);

int server_port = 3000;

String tag_cache;
char cache_buf[25];

String cacheContents;

// Initialize the Ethernet client library
EthernetClient reader1_client;
EthernetClient reader2_client;

// strings for storing results from web server
String reader1_httpresponse = "";
String reader2_httpresponse = "";

// variables for storing system status
volatile long reader1 = 0;
volatile long reader2 = 0;
volatile byte  reader1Count = 0;
volatile byte  reader2Count = 0;

bool relay1_authorized = false;
bool relay1_cache_authorized = false;
bool relay2_authorized = false;
bool relay2_cache_authorized = false;

bool relay1high = false; 
bool relay2high = false;

unsigned long relay1timer=0;
unsigned long relay2timer=0;

bool debug = false;

const int chipSelect = 9;

/*
int freeRam () {
  extern int __heap_start, *__brkval; 
  int v; 
  return (int) &v - (__brkval == 0 ? (int) &__heap_start : (int) __brkval); 
}

void printRam(char *msg){
  Serial.print(msg);
  Serial.print(": ");
  Serial.println(freeRam());
}
*/

void setup() {

  Serial.begin(57600);

  pcattach.PCattachInterrupt(reader1Pins[0], callReader1Zero, CHANGE); 
  pcattach.PCattachInterrupt(reader1Pins[1], callReader1One,  CHANGE);  
  pcattach.PCattachInterrupt(reader2Pins[0], callReader2Zero, CHANGE); 
  pcattach.PCattachInterrupt(reader2Pins[1], callReader2One,  CHANGE);  
  
  // setup wiegand readers
  wiegand26.initReaderOne();
  wiegand26.initReaderTwo();

  //Initialize relay outputs
  pinMode(RELAYPIN1, OUTPUT);                                                      
  digitalWrite(RELAYPIN1, LOW);                  // Set the relay to LOW (off)
  pinMode(RELAYPIN2, OUTPUT);                                                      
  digitalWrite(RELAYPIN2, LOW);                  // Set the relay to LOW (off)

  // make sure that the default chip select pin is set to
  // output, even if you don't use it:
  pinMode(10, OUTPUT);

  Ethernet.begin(mac, ip);

  Serial.println("OpenAccess HTTP started...");

  if (!SD.begin(chipSelect)) {
    Serial.println("Card failed, or not present");
    // don't do anything more:
    return;
  }
}


bool updateCache(bool auth) {
  if (SD.exists(cache_buf)){
    SD.remove(cache_buf);
  }
  if (auth) {
    File cacheFile = SD.open(cache_buf, FILE_WRITE);
      
    if(cacheFile) {
      cacheFile.println("200:");
      cacheFile.close();
      return true;
    }
    return false;
  }
  return false;
} 


bool checkCache(volatile long &tag) {
  tag_cache = "/cache/" + String(tag, HEX);
  tag_cache.toCharArray(cache_buf, tag_cache.length()+1);

  if (SD.exists(cache_buf)) {

    File cacheFile = SD.open(cache_buf);

    if (cacheFile) {
      cacheContents = "";
      while (cacheFile.available()) {
        char cChar = cacheFile.read();
        cacheContents += cChar;
      }
      cacheFile.close();
    }
    // if the file isn't open, pop up an error:
    else {
      Serial.println("error opening cache");
    }
   
    Serial.print("cache: ");
    Serial.println(cacheContents); 

    return true;
  }
  return false;
}


void do_relays(bool &relay_authorized, bool &relay_high, unsigned long &relay_timer, byte relay_num){
  if(relay_authorized && relay_high) {
    // calculate current time elapsed
    long currentTime = millis() - relay_timer;
    // if time entirely elapsed, deauthorize.

    if(currentTime >= RELAYDELAY) {
      relay_authorized = false;
    }
    
  }
  if(!relay_authorized && relay_high) {
    // not authorized -- turn off relay
    relayLow(relay_num);
    if(relay_num == 1){
      wiegand26.initReaderOne();                     // Reset for next tag scan  
    }
    if(relay_num == 2){
      wiegand26.initReaderTwo();                     // Reset for next tag scan       
    }
  }
  if(relay_authorized && !relay_high) {
    // authorized -- turn on relay
    relayHigh(relay_num);
    if(relay_num == 1){
      wiegand26.initReaderOne();                     // Reset for next tag scan  
    }
    if(relay_num == 2){
      wiegand26.initReaderTwo();                     // Reset for next tag scan       
    }
  }
}

void do_reader(volatile byte &reader_count, volatile long &reader, bool &relay_cache_authorized, bool &relay_authorized, Client &reader_client, int reader_num, String &reader_httpresponse){

  if(reader_count >= 26)
  {                           //  When tag presented to reader1 (No keypad on this reader)
     if (checkCache(reader)){
      relay_cache_authorized = true;
     }
     else {
      relay_cache_authorized = false;
     }
     
     Serial.print("auth gateway... ");
  
     // if you get a connection, report back via serial:
     if (reader_client.connect(server,server_port))
     {
        Serial.println("ok!");
        
        Serial.print(http1);   
        Serial.print(reader, HEX);
        Serial.println(http2);
        Serial.println();
        
        reader_client.print(http1);   
        reader_client.print(reader, HEX);
        reader_client.println(http2);
        reader_client.println();

        // reset values coming from http
        reader_httpresponse = "";
        relay_authorized = false;
     }
     else 
     {
        // kf you didn't get a connection to the server:
        Serial.println("failed!");
        relay_authorized = relay_cache_authorized;
        relay_cache_authorized = false;
     }
     if(reader_num == 1){
      wiegand26.initReaderOne();                     // Reset for next tag scan  
     }
     if(reader_num == 2){
      wiegand26.initReaderTwo();
      }
     
  }

  while (reader_client.available()) {
    char thisChar = reader_client.read();
    // We only care about the HTTP response code
    // So well flush the buffer after the first carriage return
    if (thisChar == '\r'){
      reader_client.flush();
      break;
    }
    reader_httpresponse += thisChar;
  }
  
  if(!reader_client.available() && reader_httpresponse.length()>0) { 

    Serial.println("Response: ");
    Serial.println(reader_httpresponse);

    if ( reader_httpresponse.substring(0,4) == "HTTP" ) {

      if ( reader_httpresponse.substring(9,12) == "200" ) {
        Serial.println("200 GOOD");
        updateCache(true);
        relay_authorized = true;
      }

      if ( reader_httpresponse.substring(9,12) == "401" ) {
        Serial.println("401 BAD");
        updateCache(false);
        relay_authorized = false;
      }
    }

    reader_httpresponse = "";
  }
  
  // if the server's disconnected, stop the client:
  if (!reader_client.connected()) {
    reader_client.stop();
  }

}



void loop()                                     // Main branch, runs over and over again
{ 

  // check relay timer -- if expired, remove authorization
  do_relays(relay1_authorized, relay1high, relay1timer, 1);
  do_relays(relay2_authorized, relay2high, relay2timer, 2);

  //////////////////////////  
  // Reader input/authentication section  
  //////////////////////////

  do_reader(reader1Count, reader1, relay1_cache_authorized, relay1_authorized, reader1_client, 1, reader1_httpresponse);
  do_reader(reader2Count, reader2, relay2_cache_authorized, relay2_authorized, reader2_client, 2, reader2_httpresponse);
    

  
} // End of loop()

void relayHigh(byte input) {          //Send an unlock signal to the door and flash the Door LED


byte dp=1;
  if(input == 1) {
    relay1timer = millis();
    dp=RELAYPIN1;
  }
  if(input == 2){
    relay2timer = millis();
    dp=RELAYPIN2;
  }
    
  digitalWrite(dp, HIGH);
  
  if (input == 1) {
   relay1high = true;
  }
  if (input == 2) {
    relay2high = true;
  }
  
  Serial.print("Relay ");
  Serial.print(input,DEC);
  Serial.println(" high");

}

void relayLow(byte input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) {
    dp=RELAYPIN1; }
  if(input == 2){
    dp=RELAYPIN2; }

  digitalWrite(dp, LOW);

  if (input == 1) {
    relay1high = false;
  }
  if (input == 2) {
    relay2high = false;
  }

  Serial.print("Relay ");
  Serial.print(input,DEC);
  Serial.println(" low");

}


/* Wrapper functions for interrupt attachment
 Could be cleaned up in library?
 */
void callReader1Zero(){wiegand26.reader1Zero();}
void callReader1One(){wiegand26.reader1One();}

void callReader2Zero(){wiegand26.reader2Zero();}
void callReader2One(){wiegand26.reader2One();}

