import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert'; // For json decoding
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geocoding/geocoding.dart';

Future<Map<String, dynamic>> loadConfig() async {
  final jsonString = await rootBundle.loadString('assets/config.json');
  return json.decode(jsonString);
}

typedef OnAmenityTap = void Function(
    String name, double lat, double lon, String amenity);

Future<List<LatLng>> fetchRoute(
    double startLat, double startLon, double endLat, double endLon) async {
  final config = await loadConfig();
  final String apiKey = config['api_key'];
  const String apiUrl =
      'https://api.openrouteservice.org/v2/directions/driving-car/geojson';

  final response = await http.post(
    Uri.parse(apiUrl),
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
      'Authorization': apiKey,
    },
    body: jsonEncode({
      "coordinates": [
        [startLon, startLat],
        [endLon, endLat]
      ],
    }),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    final List<dynamic> coordinates =
        data['features'][0]['geometry']['coordinates'];
    return coordinates.map((coord) => LatLng(coord[1], coord[0])).toList();
  } else {
    throw Exception('Failed to load route: ${response.body}');
  }
}

Future<List<dynamic>> fetchIsochrones(double lat, double lon) async {
  final config = await loadConfig();
  final String apiKey = config['api_key'];

  const String apiUrl =
      'https://api.openrouteservice.org/v2/isochrones/driving-car';

  final response = await http.post(
    Uri.parse(apiUrl),
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
      'Authorization': apiKey,
    },
    body: jsonEncode({
      "locations": [
        [lon, lat]
      ],
      "range": [500],
      "attributes": ["area"],
      "range_type": "time",
      "area_units": "m"
    }),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    final List<dynamic> coordinates =
        data['features'][0]['geometry']['coordinates'][0];
    return coordinates;
  } else {
    throw Exception('Failed to load isochrones');
  }
}

Future<List<Marker>> fetchLocations(OnAmenityTap onAmenityTap) async {
  const overpassUrl = 'https://overpass-api.de/api/interpreter';
  const query = '[out:json][timeout:60];'
      'area["boundary"~"administrative"]["name"~"Berlin"];'
      'node(area)["amenity"~"fire_station|police"];'
      'out;';

  final response = await http.get(
    Uri.parse('$overpassUrl?data=$query'),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    final elements = data['elements'] as List;

    return elements.map((element) {
      final lat = element['lat'];
      final lon = element['lon'];
      final amenity = element['tags']['amenity'];
      final name = element['tags']['name'] ?? 'Unknown';

      Color markerColor = Colors.red; // Default to red
      if (amenity == 'fire_station') {
        markerColor = Colors.red;
      } else if (amenity == 'police') {
        markerColor = Colors.blue;
      }

      return Marker(
        width: 80.0,
        height: 80.0,
        point: LatLng(lat, lon),
        child: GestureDetector(
          onTap: () => onAmenityTap(name, lat, lon, amenity),
          child: Icon(
            Icons.location_pin,
            color: markerColor,
            size: 40.0, // Adjust the size as needed
          ),
        ),
      );
    }).toList();
  } else {
    throw Exception('Failed to load locations from Overpass API');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Required for async main
  final config = await loadConfig();
  final apiKey = config['api_key'];

  // Now you can use apiKey for your API calls
  runApp(MyApp(apiKey: apiKey));
}

class MyApp extends StatelessWidget {
  final String apiKey;

  MyApp({Key? key, required this.apiKey}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomeScreen(), // Updated to use HomeScreen
    );
  }
}

class MapWidget extends StatefulWidget {
  @override
  _MapWidgetState createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  late Future<List<Marker>> futureMarkers;
  Marker? userLocationMarker;
  Timer? locationUpdateTimer;
  List<Marker> apiMarkers = [];
  List<LatLng> userIsochronePoints = [];
  List<LatLng> amenityIsochronePoints = [];
  Polyline? routePolyline;

  @override
  void initState() {
    super.initState();
    futureMarkers = fetchLocations(showAmenityDetails).then((markers) {
      apiMarkers = markers;
      return markers;
    });
    _getUserLocationAndUpdateIsochrone();
    locationUpdateTimer = Timer.periodic(Duration(seconds: 5),
        (Timer t) => _getUserLocationAndUpdateIsochrone());
  }

  @override
  void dispose() {
    locationUpdateTimer?.cancel();
    super.dispose();
  }

  void _getUserLocationAndUpdateIsochrone() async {
    // Fetch user location
    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    // Update user location marker
    setState(() {
      userLocationMarker = Marker(
        width: 50.0,
        height: 50.0,
        point: LatLng(position.latitude, position.longitude),
        child: Icon(Icons.person_pin_circle, color: Colors.green, size: 50.0),
      );
    });

    // Fetch and update user isochrone
    fetchIsochrones(position.latitude, position.longitude).then((points) {
      setState(() {
        userIsochronePoints = List<LatLng>.from(
            points.map((coord) => LatLng(coord[1], coord[0])));
      });
    });
  }

  void showAmenityDetails(
      String name, double lat, double lon, String amenity) async {
    // Reverse geocode the latitude and longitude to get the address
    List<Placemark> placemarks = await placemarkFromCoordinates(lat, lon);
    String address = placemarks.isNotEmpty
        ? "${placemarks[0].street}, ${placemarks[0].locality}, ${placemarks[0].postalCode}, ${placemarks[0].country}"
        : "Unknown address";

    // Fetch isochrones for the amenity and update the state
    fetchIsochrones(lat, lon).then((coordinates) {
      setState(() {
        amenityIsochronePoints = List<LatLng>.from(
            coordinates.map((coord) => LatLng(coord[1], coord[0])));
      });
    });

    // Show details in a dialog
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(name),
          content:
              Text('Address: $address\nType: $amenity'), // Display address here
          actions: <Widget>[
            TextButton(
              child: Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: Text('Route!'),
              onPressed: () async {
                Navigator.of(context).pop(); // Close the dialog
                Position userPosition = await Geolocator.getCurrentPosition(
                    desiredAccuracy: LocationAccuracy.high);
                fetchRoute(
                        userPosition.latitude, userPosition.longitude, lat, lon)
                    .then((routePoints) {
                  setState(() {
                    // Assuming you have a state variable to hold the route polyline
                    // Add or update the route polyline here
                    routePolyline = Polyline(
                      points: routePoints,
                      strokeWidth: 5.0,
                      color: Colors.blue,
                    );
                  });
                });
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Map'), // Provides a title for the AppBar
      ),
      drawer: AppDrawer(), // Includes the navigation drawer
      body: FutureBuilder<List<Marker>>(
        future: futureMarkers,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            List<Widget> mapLayers = [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.app',
              ),
              MarkerLayer(markers: apiMarkers),
            ];

            if (userLocationMarker != null) {
              mapLayers.add(MarkerLayer(markers: [userLocationMarker!]));
            }

            // Add isochrone layers for user and selected amenity
            if (userIsochronePoints.isNotEmpty) {
              mapLayers.add(PolygonLayer(
                polygons: [
                  Polygon(
                    points: userIsochronePoints,
                    color: Colors.green.withOpacity(0.3),
                    borderColor: Colors.green,
                    borderStrokeWidth: 2.0,
                  ),
                ],
              ));
            }

            if (amenityIsochronePoints.isNotEmpty) {
              mapLayers.add(PolygonLayer(
                polygons: [
                  Polygon(
                    points: amenityIsochronePoints,
                    color: Colors.red.withOpacity(0.3),
                    borderColor: Colors.red,
                    borderStrokeWidth: 2.0,
                  ),
                ],
              ));
            }

            if (routePolyline != null) {
              mapLayers.add(PolylineLayer(polylines: [routePolyline!]));
            }

            return FlutterMap(
              options: MapOptions(
                center: LatLng(52.5200, 13.4050), // Centered on Berlin
                zoom: 13.0,
              ),
              children: mapLayers,
            );
          } else if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }
          return Center(child: CircularProgressIndicator());
        },
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Home'),
      ),
      drawer: AppDrawer(), // We will create this next
      body: Center(
        child: Text('Welcome to the Berlin Map App!'),
      ),
    );
  }
}

class AppDrawer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          const DrawerHeader(
            decoration: BoxDecoration(
              color: Colors.blue,
            ),
            child: Text(
              'Navigation',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.map),
            title: Text('Map'),
            onTap: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (context) => MapWidget()));
            },
          ),

          ListTile(
            // New ListTile for the About page
            leading: Icon(Icons.info),
            title: Text('About'),
            onTap: () {
              Navigator.pop(context); // Close the drawer
              Navigator.push(context,
                  MaterialPageRoute(builder: (context) => AboutPage()));
            },
          ),
          // Add more ListTiles for other navigation options
        ],
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('About'),
      ),
      body: SingleChildScrollView(
        // Use SingleChildScrollView to avoid overflow on smaller screens
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(child: ImageWidget()), // Custom widget for the image
              SizedBox(height: 20), // Add space between image and headline
              HeadlineText('Our Mission'), // Custom widget for headlines
              RegularTextBlock(// Custom widget for regular text
                  'We aim to provide the best map navigation experience in Berlin, '
                  'offering real-time updates, detailed routes, and comprehensive coverage of amenities.'),
              SizedBox(height: 10),
              HeadlineText('Features'),
              RegularTextBlock(
                  'Explore detailed maps, find local amenities, and calculate routes efficiently and view isochrones of the amenities. The routing and isochrone data is provided by OpenRouteService, and the amenity data is provided by OpenStreetMap. We aim to provide a seamless experience for all users. The API profiles are 5 minute area with a car and the car routing profile.'),
              // Add more text blocks or other content as needed
            ],
          ),
        ),
      ),
    );
  }
}

class ImageWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Example image widget
    return Image.asset(
      'assets/images/dalle.webp',
      width: 300,
      height: 300,
      fit: BoxFit.cover,
    );
  }
}

class HeadlineText extends StatelessWidget {
  final String text;
  HeadlineText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .headline6, // Using theme for consistent styling
    );
  }
}

class RegularTextBlock extends StatelessWidget {
  final String text;
  RegularTextBlock(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .bodyText2, // Using theme for consistent styling
    );
  }
}
