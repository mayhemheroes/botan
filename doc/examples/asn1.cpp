/*
  A simple ASN.1 parser, similiar to 'dumpasn1' or 'openssl asn1parse', though
  without some of the bells and whistles of those. Primarily used for testing
  the BER decoder. The output format is modeled loosely on 'asn1parse -i'

  The output is actually less precise than the other decoders named, because
  the underlying BER_Decoder hides quite a bit from userspace, such as the use
  of indefinite length encodings (and the EOC markers). At some point it will
  also hide the constructed string types from the user, but right now you'll
  seem them as-is.

  Written by Jack Lloyd, November 9-10, 2003
    - Nov 22: Updated to new BER_Object format (tag -> class_tag/type_tag)
    - Nov 25: Much improved BIT STRING output
              Can deal with non-constructed taggings
              Can produce UTF-8 output

  This file is in the public domain.
*/

/*******************************************************************/

// Set this if your terminal understands UTF-8; otherwise output is in Latin-1
#define UTF8_TERMINAL 1

/*
   What level the outermost layer of stuff is at. Probably 0 or 1; asn1parse
   uses 0 as the outermost, while 1 makes more sense to me. 2+ doesn't make
   much sense at all.
*/
#define INITIAL_LEVEL 0

/*******************************************************************/

#include <botan/botan.h>
#include <botan/bigint.h>
#include <botan/der_enc.h>
#include <botan/ber_dec.h>
#include <botan/asn1_obj.h>
#include <botan/oids.h>
#include <botan/pem.h>
#include <botan/charset.h>
using namespace Botan;

#include <stdio.h>
#include <ctype.h>

void decode(BER_Decoder&, u32bit);
void emit(const std::string&, u32bit, u32bit, const std::string& = "");
std::string type_name(ASN1_Tag);

int main(int argc, char* argv[])
   {
   if(argc != 2)
      {
      printf("Usage: %s <file>\n", argv[0]);
      return 1;
      }

   try {
      DataSource_Stream in(argv[1]);

      if(!PEM_Code::matches(in))
         {
         BER_Decoder decoder(in);
         decode(decoder, INITIAL_LEVEL);
         }
      else
         {
         std::string label; // ignored
         BER_Decoder decoder(PEM_Code::decode(in, label));
         decode(decoder, INITIAL_LEVEL);
         }

   }
   catch(std::exception& e)
      {
      printf("%s\n", e.what());
      return 1;
      }
   return 0;
   }

void decode(BER_Decoder& decoder, u32bit level)
   {
   BER_Object obj = decoder.get_next_object();

   while(obj.type_tag != NO_OBJECT)
      {
      const ASN1_Tag type_tag = obj.type_tag;
      const ASN1_Tag class_tag = obj.class_tag;
      const u32bit length = obj.value.size();

      /* hack to insert the tag+length back in front of the stuff now
         that we've gotten the type info */
      DER_Encoder encoder;
      encoder.add_object(type_tag, class_tag, obj.value, obj.value.size());
      SecureVector<byte> bits = encoder.get_contents();

      BER_Decoder data(bits);

      if(class_tag & CONSTRUCTED)
         {
         BER_Decoder cons_info(obj.value);
         if(type_tag == SEQUENCE)
            {
            emit("SEQUENCE", level, length);
            decode(cons_info, level+1);
            }
         else if(type_tag == SET)
            {
            emit("SET", level, length);
            decode(cons_info, level+1);
            }
         else
            {
            std::string name;

            if((class_tag & APPLICATION) || (class_tag & CONTEXT_SPECIFIC) ||
               (class_tag & PRIVATE))
               {
               name = "cons [" + to_string(type_tag) + "]";

               if(class_tag & APPLICATION)
                  name += " appl";
               if(class_tag & CONTEXT_SPECIFIC)
                  name += " context";
               if(class_tag & PRIVATE)
                  name += " private";
               }
            else
               name = type_name(type_tag) + " (cons)";

            emit(name, level, length);
            decode(cons_info, level+1);
            }
         }
      else if(class_tag == APPLICATION || class_tag == CONTEXT_SPECIFIC ||
              class_tag == PRIVATE)
         {
         bool not_text = false;

         for(u32bit j = 0; j != bits.size(); j++)
            if(!isgraph(bits[j]) && !isspace(bits[j]))
               not_text = true;

         Pipe pipe(((not_text) ? new Hex_Encoder : 0));
         pipe.process_msg(bits);
         emit("[" + to_string(type_tag) + "]", level, length,
              pipe.read_all_as_string());
         }
      else if(type_tag == OBJECT_ID)
         {
         OID oid;
         data.decode(oid);

         std::string out = OIDS::lookup(oid);
         if(out != oid.as_string())
            out += " [" + oid.as_string() + "]";

         emit(type_name(type_tag), level, length, out);
         }
      else if(type_tag == INTEGER)
         {
         BigInt number;
         data.decode(number);

         SecureVector<byte> rep;

         /* If it's small, it's probably a number, not a hash */
         if(number.bits() <= 16)
            rep = BigInt::encode(number, BigInt::Decimal);
         else
            rep = BigInt::encode(number, BigInt::Hexadecimal);

         std::string str;
         for(u32bit j = 0; j != rep.size(); j++)
            str += (char)rep[j];

         emit(type_name(type_tag), level, length, str);
         }
      else if(type_tag == BOOLEAN)
         {
         bool boolean;
         data.decode(boolean);
         emit(type_name(type_tag),
              level, length, (boolean ? "true" : "false"));
         }
      else if(type_tag == NULL_TAG)
         {
         emit(type_name(type_tag), level, length);
         }
      else if(type_tag == OCTET_STRING)
         {
         SecureVector<byte> bits;
         data.decode(bits, type_tag);
         bool not_text = false;

         for(u32bit j = 0; j != bits.size(); j++)
            if(!isgraph(bits[j]) && !isspace(bits[j]))
               not_text = true;

         Pipe pipe(((not_text) ? new Hex_Encoder : 0));
         pipe.process_msg(bits);
         emit(type_name(type_tag), level, length, pipe.read_all_as_string());
         }
      else if(type_tag == BIT_STRING)
         {
         SecureVector<byte> bits;
         data.decode(bits, type_tag);

         std::vector<bool> bit_set;

         for(u32bit j = 0; j != bits.size(); j++)
            for(u32bit k = 0; k != 8; k++)
               bit_set.push_back((bool)((bits[bits.size()-j-1] >> (7-k)) & 1));

         std::string bit_str;
         for(u32bit j = 0; j != bit_set.size(); j++)
            {
            bool the_bit = bit_set[bit_set.size()-j-1];

            if(!the_bit && bit_str.size() == 0)
               continue;
            bit_str += (the_bit ? "1" : "0");
            }

         emit(type_name(type_tag), level, length, bit_str);
         }
      else if(type_tag == PRINTABLE_STRING ||
              type_tag == NUMERIC_STRING ||
              type_tag == IA5_STRING ||
              type_tag == T61_STRING ||
              type_tag == VISIBLE_STRING ||
              type_tag == UTF8_STRING ||
              type_tag == BMP_STRING)
         {
         ASN1_String str;
         data.decode(str);
         if(UTF8_TERMINAL)
            emit(type_name(type_tag), level, length,
                 Charset::transcode(str.iso_8859(),
                                    LATIN1_CHARSET, UTF8_CHARSET));
         else
            emit(type_name(type_tag), level, length, str.iso_8859());
         }
      else if(type_tag == UTC_TIME || type_tag == GENERALIZED_TIME)
         {
         X509_Time time;
         data.decode(time);
         emit(type_name(type_tag), level, length, time.readable_string());
         }
      else
         fprintf(stderr, "Unknown tag: class=%02X, type=%02X\n",
                 class_tag, type_tag);

      obj = decoder.get_next_object();
      }
   }

void emit(const std::string& type, u32bit level, u32bit length,
          const std::string& value)
   {
   const u32bit LIMIT = 128;
   const u32bit BIN_LIMIT = 64;

   int written = 0;
   written += printf("  d=%2d, l=%4d: ", level, length);
   for(u32bit j = INITIAL_LEVEL; j != level; j++)
      written += printf(" ");
   written += printf("%s   ", type.c_str());

   bool should_skip = false;
   if(value.length() > LIMIT) should_skip = true;
   if((type == "OCTET STRING" || type == "BIT STRING") &&
      value.length() > BIN_LIMIT)
      should_skip = true;

   if(value != "" && !should_skip)
      {
      if(written % 2 == 0) printf(" ");
      while(written < 50) written += printf("  ");
      printf(":%s\n", value.c_str());
      }
   else
      printf("\n");
   }

std::string type_name(ASN1_Tag type)
   {
   if(type == PRINTABLE_STRING) return "PRINTABLE STRING";
   if(type == NUMERIC_STRING)   return "NUMERIC STRING";
   if(type == IA5_STRING)       return "IA5 STRING";
   if(type == T61_STRING)       return "T61 STRING";
   if(type == UTF8_STRING)      return "UTF8 STRING";
   if(type == VISIBLE_STRING)   return "VISIBLE STRING";
   if(type == BMP_STRING)       return "BMP STRING";

   if(type == UTC_TIME)         return "UTC TIME";
   if(type == GENERALIZED_TIME) return "GENERALIZED TIME";

   if(type == OCTET_STRING)     return "OCTET STRING";
   if(type == BIT_STRING)       return "BIT STRING";

   if(type == INTEGER)          return "INTEGER";
   if(type == NULL_TAG)         return "NULL";
   if(type == OBJECT_ID)        return "OBJECT";
   if(type == BOOLEAN)          return "BOOLEAN";
   return "(UNKNOWN)";
   }
