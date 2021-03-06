/*******************************************************************************
 * Copyright (c) 2015, Daniel Murphy, Google
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *  * Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************/

part of box2d;

/**
 * A rigid body. These are created via World.createBody.
 *
 * @author Daniel Murphy
 */
class Body {
  static const int ISLAND_FLAG = 0x0001;
  static const int AWAKE_FLAG = 0x0002;
  static const int AUTO_SLEEP_FLAG = 0x0004;
  static const int BULLET_FLAG = 0x0008;
  static const int FIXED_ROTATION_FLAG = 0x0010;
  static const int ACTIVE_FLAG = 0x0020;
  static const int TOI_FLAG = 0x0040;

  BodyType _bodyType = BodyType.STATIC;

  int _flags = 0;

  int _islandIndex = 0;

  /**
   * The body origin transform.
   */
  final Transform _transform = Transform.zero();
  /**
   * The previous transform for particle simulation
   */
  final Transform _xf0 = Transform.zero();

  /**
   * The swept motion for CCD
   */
  final Sweep _sweep = Sweep();

  /// the linear velocity of the center of mass
  final Vector2 _linearVelocity = Vector2.zero();
  double _angularVelocity = 0.0;

  final Vector2 _force = Vector2.zero();
  double _torque = 0.0;

  final World world;
  Body _prev;
  Body _next;

  Fixture _fixtureList;
  int _fixtureCount = 0;

  JointEdge _jointList;
  ContactEdge _contactList;

  double _mass = 0.0, _invMass = 0.0;

  // Rotational inertia about the center of mass.
  double _I = 0.0, _invI = 0.0;

  double _linearDamping = 0.0;
  double angularDamping = 0.0;
  double _gravityScale = 0.0;

  double _sleepTime = 0.0;

  /// Use this to store your application specific data.
  Object userData;

  Body(final BodyDef bd, this.world) {
    assert(MathUtils.vector2IsValid(bd.position));
    assert(MathUtils.vector2IsValid(bd.linearVelocity));
    assert(bd.gravityScale >= 0.0);
    assert(bd.angularDamping >= 0.0);
    assert(bd.linearDamping >= 0.0);

    _flags = 0;

    if (bd.bullet) {
      _flags |= BULLET_FLAG;
    }
    if (bd.fixedRotation) {
      _flags |= FIXED_ROTATION_FLAG;
    }
    if (bd.allowSleep) {
      _flags |= AUTO_SLEEP_FLAG;
    }
    if (bd.awake) {
      _flags |= AWAKE_FLAG;
    }
    if (bd.active) {
      _flags |= ACTIVE_FLAG;
    }

    _transform.p.setFrom(bd.position);
    _transform.q.setAngle(bd.angle);

    _sweep.localCenter.setZero();
    _sweep.c0.setFrom(_transform.p);
    _sweep.c.setFrom(_transform.p);
    _sweep.a0 = bd.angle;
    _sweep.a = bd.angle;
    _sweep.alpha0 = 0.0;

    _jointList = null;
    _contactList = null;
    _prev = null;
    _next = null;

    _linearVelocity.setFrom(bd.linearVelocity);
    _angularVelocity = bd.angularVelocity;

    _linearDamping = bd.linearDamping;
    angularDamping = bd.angularDamping;
    _gravityScale = bd.gravityScale;

    _force.setZero();

    _sleepTime = 0.0;

    _bodyType = bd.type;

    if (_bodyType == BodyType.DYNAMIC) {
      _mass = 1.0;
      _invMass = 1.0;
    } else {
      _mass = 0.0;
      _invMass = 0.0;
    }

    _I = 0.0;
    _invI = 0.0;

    userData = bd.userData;

    _fixtureList = null;
    _fixtureCount = 0;
  }

  /**
   * Creates a fixture and attach it to this body. Use this function if you need to set some fixture
   * parameters, like friction. Otherwise you can create the fixture directly from a shape. If the
   * density is non-zero, this function automatically updates the mass of the body. Contacts are not
   * created until the next time step.
   *
   * @param def the fixture definition.
   * @warning This function is locked during callbacks.
   */
  Fixture createFixtureFromFixtureDef(FixtureDef def) {
    assert(world.isLocked() == false);

    if (world.isLocked() == true) {
      return null;
    }

    Fixture fixture = Fixture();
    fixture.create(this, def);

    if ((_flags & ACTIVE_FLAG) == ACTIVE_FLAG) {
      BroadPhase broadPhase = world._contactManager.broadPhase;
      fixture.createProxies(broadPhase, _transform);
    }

    fixture._next = _fixtureList;
    _fixtureList = fixture;
    ++_fixtureCount;

    fixture._body = this;

    // Adjust mass properties if needed.
    if (fixture._density > 0.0) {
      resetMassData();
    }

    // Let the world know we have a new fixture. This will cause new contacts
    // to be created at the beginning of the next time step.
    world._flags |= World.NEW_FIXTURE;

    return fixture;
  }

  final FixtureDef _fixDef = FixtureDef();

  /**
   * Creates a fixture from a shape and attach it to this body. This is a convenience function. Use
   * FixtureDef if you need to set parameters like friction, restitution, user data, or filtering.
   * If the density is non-zero, this function automatically updates the mass of the body.
   *
   * @param shape the shape to be cloned.
   * @param density the shape density (set to zero for static bodies).
   * @warning This function is locked during callbacks.
   */
  Fixture createFixtureFromShape(Shape shape, [double density = 0.0]) {
    _fixDef.shape = shape;
    _fixDef.density = density;

    return createFixtureFromFixtureDef(_fixDef);
  }

  /**
   * Destroy a fixture. This removes the fixture from the broad-phase and destroys all contacts
   * associated with this fixture. This will automatically adjust the mass of the body if the body
   * is dynamic and the fixture has positive density. All fixtures attached to a body are implicitly
   * destroyed when the body is destroyed.
   *
   * @param fixture the fixture to be removed.
   * @warning This function is locked during callbacks.
   */
  void destroyFixture(Fixture fixture) {
    assert(world.isLocked() == false);
    if (world.isLocked() == true) {
      return;
    }

    assert(fixture._body == this);

    // Remove the fixture from this body's singly linked list.
    assert(_fixtureCount > 0);
    Fixture node = _fixtureList;
    Fixture last = null; // java change
    bool found = false;
    while (node != null) {
      if (node == fixture) {
        node = fixture._next;
        found = true;
        break;
      }
      last = node;
      node = node._next;
    }

    // You tried to remove a shape that is not attached to this body.
    assert(found);

    // java change, remove it from the list
    if (last == null) {
      _fixtureList = fixture._next;
    } else {
      last._next = fixture._next;
    }

    // Destroy any contacts associated with the fixture.
    ContactEdge edge = _contactList;
    while (edge != null) {
      Contact c = edge.contact;
      edge = edge.next;

      Fixture fixtureA = c.fixtureA;
      Fixture fixtureB = c.fixtureB;

      if (fixture == fixtureA || fixture == fixtureB) {
        // This destroys the contact and removes it from
        // this body's contact list.
        world._contactManager.destroy(c);
      }
    }

    if ((_flags & ACTIVE_FLAG) == ACTIVE_FLAG) {
      BroadPhase broadPhase = world._contactManager.broadPhase;
      fixture.destroyProxies(broadPhase);
    }

    fixture.destroy();
    fixture._body = null;
    fixture._next = null;
    fixture = null;

    --_fixtureCount;

    // Reset the mass data.
    resetMassData();
  }

  /**
   * Set the position of the body's origin and rotation. This breaks any contacts and wakes the
   * other bodies. Manipulating a body's transform may cause non-physical behavior. Note: contacts
   * are updated on the next call to World.step().
   *
   * @param position the world position of the body's local origin.
   * @param angle the world rotation in radians.
   */
  void setTransform(Vector2 position, double angle) {
    assert(world.isLocked() == false);
    if (world.isLocked() == true) {
      return;
    }

    _transform.q.setAngle(angle);
    _transform.p.setFrom(position);

    // _sweep.c0 = _sweep.c = Mul(_xf, _sweep.localCenter);
    Transform.mulToOutUnsafeVec2(_transform, _sweep.localCenter, _sweep.c);
    _sweep.a = angle;

    _sweep.c0.setFrom(_sweep.c);
    _sweep.a0 = _sweep.a;

    BroadPhase broadPhase = world._contactManager.broadPhase;
    for (Fixture f = _fixtureList; f != null; f = f._next) {
      f.synchronize(broadPhase, _transform, _transform);
    }
  }

  /**
   * Get the world body origin position. Do not modify.
   *
   * @return the world position of the body's origin.
   */
  Vector2 get position => _transform.p;

  /**
   * Get the angle in radians.
   *
   * @return the current world rotation angle in radians.
   */
  double getAngle() {
    return _sweep.a;
  }

  /**
   * Get the world position of the center of mass. Do not modify.
   */
  Vector2 get worldCenter => _sweep.c;

  /**
   * Get the local position of the center of mass. Do not modify.
   */
  Vector2 getLocalCenter() {
    return _sweep.localCenter;
  }

  /**
   * Set the linear velocity of the center of mass.
   *
   * @param v the new linear velocity of the center of mass.
   */
  void set linearVelocity(Vector2 v) {
    if (_bodyType == BodyType.STATIC) {
      return;
    }

    if (v.dot(v) > 0.0) {
      setAwake(true);
    }

    _linearVelocity.setFrom(v);
  }

  /**
   * Get the linear velocity of the center of mass. Do not modify, instead use
   * {@link #setLinearVelocity(Vec2)}.
   *
   * @return the linear velocity of the center of mass.
   */
  Vector2 get linearVelocity => _linearVelocity;

  /**
   * Set the angular velocity.
   *
   * @param omega the new angular velocity in radians/second.
   */
  void set angularVelocity(double w) {
    if (_bodyType == BodyType.STATIC) {
      return;
    }

    if (w * w > 0.0) {
      setAwake(true);
    }

    _angularVelocity = w;
  }

  /**
   * Get the angular velocity.
   *
   * @return the angular velocity in radians/second.
   */
  double get angularVelocity {
    return _angularVelocity;
  }

  /**
   * Apply a force at a world point. If the force is not applied at the center of mass, it will
   * generate a torque and affect the angular velocity. This wakes up the body.
   *
   * @param force the world force vector, usually in Newtons (N).
   * @param point the world position of the point of application.
   */
  void applyForce(Vector2 force, Vector2 point) {
    if (_bodyType != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }

    // _force.addLocal(force);
    // Vec2 temp = tltemp.get();
    // temp.set(point).subLocal(_sweep.c);
    // _torque += Vec2.cross(temp, force);

    _force.x += force.x;
    _force.y += force.y;

    _torque +=
        (point.x - _sweep.c.x) * force.y - (point.y - _sweep.c.y) * force.x;
  }

  /**
   * Apply a force to the center of mass. This wakes up the body.
   *
   * @param force the world force vector, usually in Newtons (N).
   */
  void applyForceToCenter(Vector2 force) {
    if (_bodyType != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }

    _force.x += force.x;
    _force.y += force.y;
  }

  /**
   * Apply a torque. This affects the angular velocity without affecting the linear velocity of the
   * center of mass. This wakes up the body.
   *
   * @param torque about the z-axis (out of the screen), usually in N-m.
   */
  void applyTorque(double torque) {
    if (_bodyType != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }

    torque += torque;
  }

  /**
   * Apply an impulse at a point. This immediately modifies the velocity. It also modifies the
   * angular velocity if the point of application is not at the center of mass. This wakes up the
   * body if 'wake' is set to true. If the body is sleeping and 'wake' is false, then there is no
   * effect.
   *
   * @param impulse the world impulse vector, usually in N-seconds or kg-m/s.
   * @param point the world position of the point of application.
   * @param wake also wake up the body
   */
  void applyLinearImpulse(Vector2 impulse, Vector2 point, bool wake) {
    if (_bodyType != BodyType.DYNAMIC) {
      return;
    }

    if (!isAwake()) {
      if (wake) {
        setAwake(true);
      } else {
        return;
      }
    }

    _linearVelocity.x += impulse.x * _invMass;
    _linearVelocity.y += impulse.y * _invMass;

    _angularVelocity += _invI *
        ((point.x - _sweep.c.x) * impulse.y -
            (point.y - _sweep.c.y) * impulse.x);
  }

  /**
   * Apply an angular impulse.
   *
   * @param impulse the angular impulse in units of kg*m*m/s
   */
  void applyAngularImpulse(double impulse) {
    if (_bodyType != BodyType.DYNAMIC) {
      return;
    }

    if (isAwake() == false) {
      setAwake(true);
    }
    _angularVelocity += _invI * impulse;
  }

  /**
   * Get the total mass of the body.
   *
   * @return the mass, usually in kilograms (kg).
   */
  double get mass => _mass;

  /**
   * Get the central rotational inertia of the body.
   *
   * @return the rotational inertia, usually in kg-m^2.
   */
  double getInertia() {
    return _I +
        _mass *
            (_sweep.localCenter.x * _sweep.localCenter.x +
                _sweep.localCenter.y * _sweep.localCenter.y);
  }

  /**
   * Get the mass data of the body. The rotational inertia is relative to the center of mass.
   *
   * @return a struct containing the mass, inertia and center of the body.
   */
  void getMassData(MassData data) {
    // data.mass = _mass;
    // data.I = _I + _mass * Vec2.dot(_sweep.localCenter, _sweep.localCenter);
    // data.center.set(_sweep.localCenter);

    data.mass = _mass;
    data.I = _I +
        _mass *
            (_sweep.localCenter.x * _sweep.localCenter.x +
                _sweep.localCenter.y * _sweep.localCenter.y);
    data.center.x = _sweep.localCenter.x;
    data.center.y = _sweep.localCenter.y;
  }

  /**
   * Set the mass properties to override the mass properties of the fixtures. Note that this changes
   * the center of mass position. Note that creating or destroying fixtures can also alter the mass.
   * This function has no effect if the body isn't dynamic.
   *
   * @param massData the mass properties.
   */
  void setMassData(MassData massData) {
    // TODO_ERIN adjust linear velocity and torque to account for movement of center.
    assert(world.isLocked() == false);
    if (world.isLocked() == true) {
      return;
    }

    if (_bodyType != BodyType.DYNAMIC) {
      return;
    }

    _invMass = 0.0;
    _I = 0.0;
    _invI = 0.0;

    _mass = massData.mass;
    if (_mass <= 0.0) {
      _mass = 1.0;
    }

    _invMass = 1.0 / _mass;

    if (massData.I > 0.0 && (_flags & FIXED_ROTATION_FLAG) == 0.0) {
      _I = massData.I - _mass * massData.center.dot(massData.center);
      assert(_I > 0.0);
      _invI = 1.0 / _I;
    }

    final Vector2 oldCenter = world.getPool().popVec2();
    // Move center of mass.
    oldCenter.setFrom(_sweep.c);
    _sweep.localCenter.setFrom(massData.center);
    // _sweep.c0 = _sweep.c = Mul(_xf, _sweep.localCenter);
    Transform.mulToOutUnsafeVec2(_transform, _sweep.localCenter, _sweep.c0);
    _sweep.c.setFrom(_sweep.c0);

    // Update center of mass velocity.
    // _linearVelocity += Cross(_angularVelocity, _sweep.c - oldCenter);
    final Vector2 temp = world.getPool().popVec2();
    (temp..setFrom(_sweep.c)).sub(oldCenter);
    temp.scaleOrthogonalInto(_angularVelocity, temp);
    _linearVelocity.add(temp);

    world.getPool().pushVec2(2);
  }

  final MassData _pmd = MassData();

  /**
   * This resets the mass properties to the sum of the mass properties of the fixtures. This
   * normally does not need to be called unless you called setMassData to override the mass and you
   * later want to reset the mass.
   */
  void resetMassData() {
    // Compute mass data from shapes. Each shape has its own density.
    _mass = 0.0;
    _invMass = 0.0;
    _I = 0.0;
    _invI = 0.0;
    _sweep.localCenter.setZero();

    // Static and kinematic bodies have zero mass.
    if (_bodyType == BodyType.STATIC || _bodyType == BodyType.KINEMATIC) {
      // _sweep.c0 = _sweep.c = _xf.position;
      _sweep.c0.setFrom(_transform.p);
      _sweep.c.setFrom(_transform.p);
      _sweep.a0 = _sweep.a;
      return;
    }

    assert(_bodyType == BodyType.DYNAMIC);

    // Accumulate mass over all fixtures.
    final Vector2 localCenter = world.getPool().popVec2();
    localCenter.setZero();
    final Vector2 temp = world.getPool().popVec2();
    final MassData massData = _pmd;
    for (Fixture f = _fixtureList; f != null; f = f._next) {
      if (f._density == 0.0) {
        continue;
      }
      f.getMassData(massData);
      _mass += massData.mass;
      // center += massData.mass * massData.center;
      (temp..setFrom(massData.center)).scale(massData.mass);
      localCenter.add(temp);
      _I += massData.I;
    }

    // Compute center of mass.
    if (_mass > 0.0) {
      _invMass = 1.0 / _mass;
      localCenter.scale(_invMass);
    } else {
      // Force all dynamic bodies to have a positive mass.
      _mass = 1.0;
      _invMass = 1.0;
    }

    if (_I > 0.0 && (_flags & FIXED_ROTATION_FLAG) == 0.0) {
      // Center the inertia about the center of mass.
      _I -= _mass * localCenter.dot(localCenter);
      assert(_I > 0.0);
      _invI = 1.0 / _I;
    } else {
      _I = 0.0;
      _invI = 0.0;
    }

    Vector2 oldCenter = world.getPool().popVec2();
    // Move center of mass.
    oldCenter.setFrom(_sweep.c);
    _sweep.localCenter.setFrom(localCenter);
    // _sweep.c0 = _sweep.c = Mul(_xf, _sweep.localCenter);
    Transform.mulToOutUnsafeVec2(_transform, _sweep.localCenter, _sweep.c0);
    _sweep.c.setFrom(_sweep.c0);

    // Update center of mass velocity.
    // _linearVelocity += Cross(_angularVelocity, _sweep.c - oldCenter);
    (temp..setFrom(_sweep.c)).sub(oldCenter);

    final Vector2 temp2 = oldCenter;
    temp.scaleOrthogonalInto(_angularVelocity, temp2);
    _linearVelocity.add(temp2);

    world.getPool().pushVec2(3);
  }

  /**
   * Get the world coordinates of a point given the local coordinates.
   *
   * @param localPoint a point on the body measured relative the the body's origin.
   * @return the same point expressed in world coordinates.
   */
  Vector2 getWorldPoint(Vector2 localPoint) {
    Vector2 v = Vector2.zero();
    getWorldPointToOut(localPoint, v);
    return v;
  }

  void getWorldPointToOut(Vector2 localPoint, Vector2 out) {
    Transform.mulToOutVec2(_transform, localPoint, out);
  }

  /**
   * Get the world coordinates of a vector given the local coordinates.
   *
   * @param localVector a vector fixed in the body.
   * @return the same vector expressed in world coordinates.
   */
  Vector2 getWorldVector(Vector2 localVector) {
    Vector2 out = Vector2.zero();
    getWorldVectorToOut(localVector, out);
    return out;
  }

  void getWorldVectorToOut(Vector2 localVector, Vector2 out) {
    Rot.mulToOut(_transform.q, localVector, out);
  }

  void getWorldVectorToOutUnsafe(Vector2 localVector, Vector2 out) {
    Rot.mulToOutUnsafe(_transform.q, localVector, out);
  }

  /**
   * Gets a local point relative to the body's origin given a world point.
   *
   * @param a point in world coordinates.
   * @return the corresponding local point relative to the body's origin.
   */
  Vector2 getLocalPoint(Vector2 worldPoint) {
    Vector2 out = Vector2.zero();
    getLocalPointToOut(worldPoint, out);
    return out;
  }

  void getLocalPointToOut(Vector2 worldPoint, Vector2 out) {
    Transform.mulTransToOutVec2(_transform, worldPoint, out);
  }

  /**
   * Gets a local vector given a world vector.
   *
   * @param a vector in world coordinates.
   * @return the corresponding local vector.
   */
  Vector2 getLocalVector(Vector2 worldVector) {
    Vector2 out = Vector2.zero();
    getLocalVectorToOut(worldVector, out);
    return out;
  }

  void getLocalVectorToOut(Vector2 worldVector, Vector2 out) {
    Rot.mulTransVec2(_transform.q, worldVector, out);
  }

  void getLocalVectorToOutUnsafe(Vector2 worldVector, Vector2 out) {
    Rot.mulTransUnsafeVec2(_transform.q, worldVector, out);
  }

  /**
   * Get the world linear velocity of a world point attached to this body.
   *
   * @param a point in world coordinates.
   * @return the world velocity of a point.
   */
  Vector2 getLinearVelocityFromWorldPoint(Vector2 worldPoint) {
    Vector2 out = Vector2.zero();
    getLinearVelocityFromWorldPointToOut(worldPoint, out);
    return out;
  }

  void getLinearVelocityFromWorldPointToOut(Vector2 worldPoint, Vector2 out) {
    final double tempX = worldPoint.x - _sweep.c.x;
    final double tempY = worldPoint.y - _sweep.c.y;
    out.x = -_angularVelocity * tempY + _linearVelocity.x;
    out.y = _angularVelocity * tempX + _linearVelocity.y;
  }

  /**
   * Get the world velocity of a local point.
   *
   * @param a point in local coordinates.
   * @return the world velocity of a point.
   */
  Vector2 getLinearVelocityFromLocalPoint(Vector2 localPoint) {
    Vector2 out = Vector2.zero();
    getLinearVelocityFromLocalPointToOut(localPoint, out);
    return out;
  }

  void getLinearVelocityFromLocalPointToOut(Vector2 localPoint, Vector2 out) {
    getWorldPointToOut(localPoint, out);
    getLinearVelocityFromWorldPointToOut(out, out);
  }

  BodyType getType() {
    return _bodyType;
  }

  /**
   * Set the type of this body. This may alter the mass and velocity.
   *
   * @param type
   */
  void setType(BodyType type) {
    assert(world.isLocked() == false);
    if (world.isLocked() == true) {
      return;
    }

    if (_bodyType == type) {
      return;
    }

    _bodyType = type;

    resetMassData();

    if (_bodyType == BodyType.STATIC) {
      _linearVelocity.setZero();
      _angularVelocity = 0.0;
      _sweep.a0 = _sweep.a;
      _sweep.c0.setFrom(_sweep.c);
      synchronizeFixtures();
    }

    setAwake(true);

    _force.setZero();
    _torque = 0.0;

    // Delete the attached contacts.
    ContactEdge ce = _contactList;
    while (ce != null) {
      ContactEdge ce0 = ce;
      ce = ce.next;
      world._contactManager.destroy(ce0.contact);
    }
    _contactList = null;

    // Touch the proxies so that new contacts will be created (when appropriate)
    BroadPhase broadPhase = world._contactManager.broadPhase;
    for (Fixture f = _fixtureList; f != null; f = f._next) {
      int proxyCount = f._proxyCount;
      for (int i = 0; i < proxyCount; ++i) {
        broadPhase.touchProxy(f._proxies[i].proxyId);
      }
    }
  }

  /** Is this body treated like a bullet for continuous collision detection? */
  bool isBullet() {
    return (_flags & BULLET_FLAG) == BULLET_FLAG;
  }

  /** Should this body be treated like a bullet for continuous collision detection? */
  void setBullet(bool flag) {
    if (flag) {
      _flags |= BULLET_FLAG;
    } else {
      _flags &= ~BULLET_FLAG;
    }
  }

  /**
   * You can disable sleeping on this body. If you disable sleeping, the body will be woken.
   *
   * @param flag
   */
  void setSleepingAllowed(bool flag) {
    if (flag) {
      _flags |= AUTO_SLEEP_FLAG;
    } else {
      _flags &= ~AUTO_SLEEP_FLAG;
      setAwake(true);
    }
  }

  /**
   * Is this body allowed to sleep
   *
   * @return
   */
  bool isSleepingAllowed() {
    return (_flags & AUTO_SLEEP_FLAG) == AUTO_SLEEP_FLAG;
  }

  /**
   * Set the sleep state of the body. A sleeping body has very low CPU cost.
   *
   * @param flag set to true to put body to sleep, false to wake it.
   * @param flag
   */
  void setAwake(bool flag) {
    if (flag) {
      if ((_flags & AWAKE_FLAG) == 0) {
        _flags |= AWAKE_FLAG;
        _sleepTime = 0.0;
      }
    } else {
      _flags &= ~AWAKE_FLAG;
      _sleepTime = 0.0;
      _linearVelocity.setZero();
      _angularVelocity = 0.0;
      _force.setZero();
      _torque = 0.0;
    }
  }

  /**
   * Get the sleeping state of this body.
   *
   * @return true if the body is awake.
   */
  bool isAwake() {
    return (_flags & AWAKE_FLAG) == AWAKE_FLAG;
  }

  /**
   * Set the active state of the body. An inactive body is not simulated and cannot be collided with
   * or woken up. If you pass a flag of true, all fixtures will be added to the broad-phase. If you
   * pass a flag of false, all fixtures will be removed from the broad-phase and all contacts will
   * be destroyed. Fixtures and joints are otherwise unaffected. You may continue to create/destroy
   * fixtures and joints on inactive bodies. Fixtures on an inactive body are implicitly inactive
   * and will not participate in collisions, ray-casts, or queries. Joints connected to an inactive
   * body are implicitly inactive. An inactive body is still owned by a World object and remains in
   * the body list.
   *
   * @param flag
   */
  void setActive(bool flag) {
    assert(world.isLocked() == false);

    if (flag == isActive()) {
      return;
    }

    if (flag) {
      _flags |= ACTIVE_FLAG;

      // Create all proxies.
      BroadPhase broadPhase = world._contactManager.broadPhase;
      for (Fixture f = _fixtureList; f != null; f = f._next) {
        f.createProxies(broadPhase, _transform);
      }

      // Contacts are created the next time step.
    } else {
      _flags &= ~ACTIVE_FLAG;

      // Destroy all proxies.
      BroadPhase broadPhase = world._contactManager.broadPhase;
      for (Fixture f = _fixtureList; f != null; f = f._next) {
        f.destroyProxies(broadPhase);
      }

      // Destroy the attached contacts.
      ContactEdge ce = _contactList;
      while (ce != null) {
        ContactEdge ce0 = ce;
        ce = ce.next;
        world._contactManager.destroy(ce0.contact);
      }
      _contactList = null;
    }
  }

  /**
   * Get the active state of the body.
   *
   * @return
   */
  bool isActive() {
    return (_flags & ACTIVE_FLAG) == ACTIVE_FLAG;
  }

  /**
   * Set this body to have fixed rotation. This causes the mass to be reset.
   *
   * @param flag
   */
  void setFixedRotation(bool flag) {
    if (flag) {
      _flags |= FIXED_ROTATION_FLAG;
    } else {
      _flags &= ~FIXED_ROTATION_FLAG;
    }

    resetMassData();
  }

  /**
   * Does this body have fixed rotation?
   *
   * @return
   */
  bool isFixedRotation() {
    return (_flags & FIXED_ROTATION_FLAG) == FIXED_ROTATION_FLAG;
  }

  /** Get the list of all fixtures attached to this body. */
  Fixture getFixtureList() {
    return _fixtureList;
  }

  /** Get the list of all joints attached to this body. */
  JointEdge getJointList() {
    return _jointList;
  }

  /**
   * Get the list of all contacts attached to this body.
   *
   * @warning this list changes during the time step and you may miss some collisions if you don't
   *          use ContactListener.
   */
  ContactEdge getContactList() {
    return _contactList;
  }

  /** Get the next body in the world's body list. */
  Body getNext() {
    return _next;
  }

  // djm pooling
  final Transform _pxf = Transform.zero();

  void synchronizeFixtures() {
    final Transform xf1 = _pxf;
    // xf1.position = _sweep.c0 - Mul(xf1.R, _sweep.localCenter);

    // xf1.q.set(_sweep.a0);
    // Rot.mulToOutUnsafe(xf1.q, _sweep.localCenter, xf1.p);
    // xf1.p.mulLocal(-1).addLocal(_sweep.c0);
    // inlined:
    xf1.q.s = Math.sin(_sweep.a0);
    xf1.q.c = Math.cos(_sweep.a0);
    xf1.p.x = _sweep.c0.x -
        xf1.q.c * _sweep.localCenter.x +
        xf1.q.s * _sweep.localCenter.y;
    xf1.p.y = _sweep.c0.y -
        xf1.q.s * _sweep.localCenter.x -
        xf1.q.c * _sweep.localCenter.y;
    // end inline

    for (Fixture f = _fixtureList; f != null; f = f._next) {
      f.synchronize(world._contactManager.broadPhase, xf1, _transform);
    }
  }

  void synchronizeTransform() {
    // _xf.q.set(_sweep.a);
    //
    // // _xf.position = _sweep.c - Mul(_xf.R, _sweep.localCenter);
    // Rot.mulToOutUnsafe(_xf.q, _sweep.localCenter, _xf.p);
    // _xf.p.mulLocal(-1).addLocal(_sweep.c);
    //
    _transform.q.s = Math.sin(_sweep.a);
    _transform.q.c = Math.cos(_sweep.a);
    Rot q = _transform.q;
    Vector2 v = _sweep.localCenter;
    _transform.p.x = _sweep.c.x - q.c * v.x + q.s * v.y;
    _transform.p.y = _sweep.c.y - q.s * v.x - q.c * v.y;
  }

  /**
   * This is used to prevent connected bodies from colliding. It may lie, depending on the
   * collideConnected flag.
   *
   * @param other
   * @return
   */
  bool shouldCollide(Body other) {
    // At least one body should be dynamic.
    if (_bodyType != BodyType.DYNAMIC && other._bodyType != BodyType.DYNAMIC) {
      return false;
    }

    // Does a joint prevent collision?
    for (JointEdge jn = _jointList; jn != null; jn = jn.next) {
      if (jn.other == other) {
        if (jn.joint.getCollideConnected() == false) {
          return false;
        }
      }
    }

    return true;
  }

  void advance(double t) {
    // Advance to the new safe time. This doesn't sync the broad-phase.
    _sweep.advance(t);
    _sweep.c.setFrom(_sweep.c0);
    _sweep.a = _sweep.a0;
    _transform.q.setAngle(_sweep.a);
    // _xf.position = _sweep.c - Mul(_xf.R, _sweep.localCenter);
    Rot.mulToOutUnsafe(_transform.q, _sweep.localCenter, _transform.p);
    (_transform.p..scale(-1.0)).add(_sweep.c);
  }

  String toString() {
    return "Body[pos: ${position} linVel: ${linearVelocity} angVel: ${angularVelocity}]";
  }
}
