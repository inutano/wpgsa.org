// result.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // set filename to page header
  setResultPageHeader();
});

// functions
// common

var getUrlParameter = function getUrlParameter(sParam) {
  var sPageURL = decodeURIComponent(window.location.search.substring(1)),
    sURLVariables = sPageURL.split('&'),
    sParameterName,
    i;

  for (i = 0; i < sURLVariables.length; i++) {
    sParameterName = sURLVariables[i].split('=');
    if (sParameterName[0] === sParam) {
      return sParameterName[1] === undefined ? true : sParameterName[1];
    }
  }
};

// result page rendering

var GetResult = {
  input_file: {
    filename: function(uuid){
      var defer = $.Deferred();
      $.ajax({
        url: "/wpgsa/result?uuid=" + uuid + "&type=filepath",
        type: 'GET',
        success: defer.resolve,
        error: defer.reject
      });
      return defer.promise();
    }
  }
};

function setResultPageHeader(){
  var uuid = getUrlParameter('uuid');
  GetResult.input_file.filename(uuid).done(function(text){
    $('h1').append("wPGSA Result: "+text);
  });
}
